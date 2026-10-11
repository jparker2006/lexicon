// Gold review page (#51). Talks only to the server that served it
// (scorer/lexicon_scorer/review.py); its Content-Security-Policy refuses anything else.
"use strict";

const MODELS = ["parakeet", "wispr"];
const LABEL = { parakeet: "A chosen", wispr: "B chosen", typed: "typed" };
const RATES = [0.75, 1, 1.25, 1.5, 1.75, 2];

let clips = [];
let answers = {};
let at = 0;
let mode = "normal"; // normal | edit | mark
let cursor = { model: "parakeet", word: 0 };
let rate = 1;
let error = "";
// An answer or mark is being saved (a few ms): keys pressed meanwhile are
// dropped, so a quick second key never lands on the wrong clip or undoes the first.
let busy = false;
let moves = Promise.resolve();
let clearing = null; // the clip whose answer one Backspace asked to clear
let difference = -1; // which difference D last jumped to, on this clip
const audio = new Audio();
const blobs = new Map(); // clip id -> Promise of an object URL

const $ = (id) => document.getElementById(id);
// The server's key, from the link's fragment (never sent by the browser itself).
const KEY = new URLSearchParams(location.hash.slice(1)).get("key") || "";
const keyed = (headers = {}) => ({ ...headers, "X-Review-Key": KEY });

async function call(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: keyed({ "Content-Type": "application/json" }),
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${response.status}`);
  return response.json();
}

function fail(message) {
  error = message;
  render();
}

async function save(path, body) {
  $("saved").textContent = "Saving";
  try {
    const result = await call(path, body);
    error = "";
    $("saved").textContent = "Saved";
    return result;
  } catch {
    fail("Not saved. Is scripts/test-set.sh review still running? It opens a new page each run.");
    $("saved").textContent = "";
    return null;
  }
}

// Words

const key = (word) => word.toLowerCase().replace(/[^\p{L}\p{N}']/gu, "");

// Which words of a and b are not in their longest common subsequence: where the two texts differ.
function differing(a, b) {
  const ka = a.map(key), kb = b.map(key);
  const n = a.length, m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = ka[i] === kb[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const da = new Set(), db = new Set();
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (ka[i] === kb[j]) { i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) da.add(i++);
    else db.add(j++);
  }
  while (i < n) da.add(i++);
  while (j < m) db.add(j++);
  return { parakeet: da, wispr: db };
}

// Audio

function blob(clip) {
  if (!blobs.has(clip.id)) {
    blobs.set(clip.id, fetch(`/audio/${encodeURIComponent(clip.id)}`, { headers: keyed() }).then((r) => {
      if (!r.ok) throw new Error(`${r.status}`);
      return r.blob();
    }).then((b) => URL.createObjectURL(b), (e) => {
      blobs.delete(clip.id); // try again next time
      throw e;
    }));
  }
  return blobs.get(clip.id);
}

// Keeps the clips around this one loaded, and lets the rest go.
function prefetch() {
  const keep = new Set([at - 1, at, at + 1, at + 2].filter((i) => i >= 0 && i < clips.length).map((i) => clips[i].id));
  for (const [id, url] of blobs) {
    if (!keep.has(id)) {
      url.then(URL.revokeObjectURL, () => {});
      blobs.delete(id);
    }
  }
  for (const id of keep) blob(clips.find((c) => c.id === id)).catch(() => {});
}

async function load() {
  const clip = clips[at];
  audio.pause();
  // Never the previous clip's audio under this clip's text, even if this one fails to load.
  audio.removeAttribute("src");
  audio.load();
  try {
    const url = await blob(clip);
    if (clips[at] !== clip) return;
    audio.src = url;
    audio.playbackRate = rate;
    audio.play().catch(() => {}); // before the first key press the browser may refuse to autoplay
  } catch {
    blobs.delete(clip.id);
    fail("Could not load this clip's audio.");
  }
  prefetch();
}

audio.addEventListener("timeupdate", renderTime);
audio.addEventListener("play", renderTime);
audio.addEventListener("pause", renderTime);
audio.addEventListener("loadedmetadata", renderTime);

function renderTime() {
  const d = Number.isFinite(audio.duration) ? audio.duration : 0;
  $("time").textContent = `${audio.currentTime.toFixed(1)} / ${d.toFixed(1)} s`;
  $("play").textContent = audio.paused ? "Play" : "Pause";
}

// Moving

function go(index) {
  if (index < 0 || index >= clips.length) return;
  at = index;
  mode = "normal";
  cursor = { model: "parakeet", word: 0 };
  difference = -1;
  // One at a time, so the server keeps the last clip, not whichever arrived last.
  const id = clips[at].id;
  moves = moves.then(() => save("/api/position", { id }));
  render();
  load();
}

function nextUnanswered() {
  for (let step = 1; step <= clips.length; step++) {
    const i = (at + step) % clips.length;
    if (!answers[clips[i].id] || answers[clips[i].id].text == null) return go(i);
  }
  $("saved").textContent = "Every clip is answered";
}

// Answering

async function answer(choice, text) {
  const clip = clips[at];
  busy = true;
  const result = await save("/api/answer", { id: clip.id, choice, text });
  busy = false;
  if (!result) return;
  answers[clip.id] = result;
  if (clips[at] !== clip) return render();
  mode = "normal";
  // A Term in another case or spacing stays on screen until it is fixed or skipped.
  if (choice !== null && result.suggestions.length === 0 && at + 1 < clips.length) go(at + 1);
  else render();
}

async function toggleMark(model, word) {
  if (busy) return;
  const clip = clips[at];
  const current = answers[clip.id] ? answers[clip.id].marks : { parakeet: [], wispr: [] };
  const marks = { parakeet: [...current.parakeet], wispr: [...current.wispr] };
  const i = marks[model].indexOf(word);
  if (i >= 0) marks[model].splice(i, 1);
  else marks[model].push(word);
  busy = true;
  const result = await save("/api/marks", { id: clip.id, marks });
  busy = false;
  if (result) answers[clip.id] = result;
  render();
}

function edit(text) {
  mode = "edit";
  render();
  const box = $("typed");
  box.value = text;
  box.focus();
  box.setSelectionRange(text.length, text.length);
}

// Drawing

function words(element, model, list, diff, marks) {
  element.replaceChildren();
  if (list.length === 0) {
    const none = document.createElement("span");
    none.className = "empty";
    none.textContent = "(no text)";
    element.append(none);
    return;
  }
  list.forEach((word, i) => {
    const span = document.createElement("span");
    span.textContent = word;
    span.dataset.word = i;
    if (diff.has(i)) span.classList.add("diff");
    if (marks.includes(i)) span.classList.add("marked");
    if (mode === "mark" && cursor.model === model && cursor.word === i) span.classList.add("at");
    element.append(span, " ");
  });
}

function hints(element, list) {
  element.textContent = list.length ? "Lexicon: " + list.map((s) => `${s.found} → ${s.written}`).join(", ") : "";
}

function render() {
  const e = $("error");
  e.hidden = !error;
  e.textContent = error;
  const clip = clips[at];
  if (!clip) {
    $("where").textContent = error ? "" : "No clips to review.";
    return;
  }
  const done = clips.filter((c) => answers[c.id] && answers[c.id].text != null).length;
  const mine = answers[clip.id] || { choice: null, text: null, marks: { parakeet: [], wispr: [] } };
  $("where").textContent = `Clip ${at + 1} of ${clips.length} · ${done} answered`;
  $("done").style.width = `${(100 * done) / clips.length}%`;
  $("split").textContent = clip.split;
  $("split").classList.toggle("held", clip.split === "held-back");
  $("reasons").textContent = clip.reasons.join(", ");
  $("rate").textContent = `${rate.toFixed(2)}x`;
  document.body.classList.toggle("marking", mode === "mark");

  const diff = differing(clip.words.parakeet, clip.words.wispr);
  for (const model of MODELS) {
    const row = $(`row-${model}`);
    words(row.querySelector(".words"), model, clip.words[model], diff[model], mine.marks[model] || []);
    hints(row.querySelector(".hints"), clip.suggestions[model]);
    row.classList.toggle("picked", mine.choice === model);
    row.classList.toggle("cursor", mode === "mark" && cursor.model === model);
  }

  $("wispr-final").textContent = clip.wispr_final || "(nothing)";
  const fixed = clip.jake_edit != null && clip.jake_edit.trim() !== "" && clip.jake_edit !== clip.wispr_final;
  $("edit-line").hidden = !fixed;
  $("jake-edit").textContent = fixed ? clip.jake_edit : "";

  $("choice").textContent = mine.choice ? LABEL[mine.choice] : "";
  const gold = $("gold-text");
  gold.className = mine.text == null || mine.text === "" ? "empty" : "";
  gold.textContent = mine.text == null ? "Not answered yet" : mine.text === "" ? "(nothing said)" : mine.text;

  const warn = $("warning");
  const suggest = mine.text != null && mine.suggestions && mine.suggestions.length > 0;
  warn.hidden = !suggest || mode === "edit";
  warn.textContent = suggest
    ? `Gold writes ${mine.suggestions.map((s) => `“${s.found}” where the Lexicon writes “${s.written}”`).join(", ")}. ` +
      "F fixes it, J moves on as it is."
    : "";

  if (clearing === clip.id) {
    warn.hidden = false;
    warn.textContent = "Press Backspace again to clear this answer.";
  }

  $("editor").hidden = mode !== "edit";
  const pointed = document.querySelector(".words span.at");
  if (pointed) pointed.scrollIntoView({ block: "nearest" });
}

// Keys

function seek(seconds) {
  audio.currentTime = Math.max(0, Math.min((audio.duration || 0), audio.currentTime + seconds));
}

// Plays from just before the next place A and B differ. There are no word
// timings, so the place is estimated from the word's share of the text: a long
// clip need not be heard whole.
function nextDifference() {
  const clip = clips[at];
  const diff = differing(clip.words.parakeet, clip.words.wispr);
  const model = diff.parakeet.size ? "parakeet" : "wispr";
  const list = [...diff[model]].sort((a, b) => a - b);
  const starts = list.filter((i, k) => k === 0 || list[k - 1] !== i - 1);
  if (starts.length === 0 || !Number.isFinite(audio.duration)) return;
  difference = (difference + 1) % starts.length;
  audio.currentTime = Math.max(0, (starts[difference] / clip.words[model].length) * audio.duration - 1.5);
  audio.play().catch(() => {});
  const word = $(`row-${model}`).querySelector(`[data-word="${starts[difference]}"]`);
  if (word) word.scrollIntoView({ block: "nearest" });
}

function setRate(step) {
  const i = Math.max(0, Math.min(RATES.length - 1, RATES.indexOf(rate) + step));
  rate = RATES[i];
  audio.playbackRate = rate;
  render();
}

function togglePlay() {
  if (audio.paused) audio.play().catch(() => {});
  else audio.pause();
}

// Letters work with Caps Lock or Shift on too.
const letter = (event) => (event.key.length === 1 ? event.key.toLowerCase() : event.key);

function markKeys(event) {
  const clip = clips[at];
  const size = clip.words[cursor.model].length;
  switch (letter(event)) {
    case "ArrowLeft": cursor.word = Math.max(0, cursor.word - 1); break;
    case "ArrowRight": cursor.word = Math.max(0, Math.min(size - 1, cursor.word + 1)); break;
    case "ArrowUp": case "ArrowDown": {
      cursor.model = cursor.model === "parakeet" ? "wispr" : "parakeet";
      cursor.word = Math.min(cursor.word, Math.max(0, clip.words[cursor.model].length - 1));
      break;
    }
    case "x": case "Enter": if (size > 0) toggleMark(cursor.model, cursor.word); return true;
    case " ": togglePlay(); return true;
    case "Escape": case "m": mode = "normal"; break;
    default: return false;
  }
  render();
  return true;
}

function editKeys(event) {
  if (event.key === "Enter" && !event.shiftKey) {
    answer("typed", $("typed").value);
    return true;
  }
  if (event.key === "Escape") {
    mode = "normal";
    render();
    return true;
  }
  return false;
}

function normalKeys(event) {
  const clip = clips[at];
  const mine = answers[clip.id];
  switch (letter(event)) {
    case " ": togglePlay(); break;
    case "d": nextDifference(); break;
    case "r": audio.currentTime = 0; audio.play().catch(() => {}); break;
    case "ArrowLeft": seek(-2); break;
    case "ArrowRight": seek(2); break;
    case "[": setRate(-1); break;
    case "]": setRate(1); break;
    case "a": answer("parakeet", null); break;
    case "b": answer("wispr", null); break;
    case "1": edit(clip.parakeet); break;
    case "2": edit(clip.wispr); break;
    case "3": edit(clip.jake_edit || clip.wispr_final || clip.wispr); break;
    case "e": edit(mine && mine.text != null ? mine.text : clip.parakeet); break;
    case "f": if (mine && mine.fixed != null && mine.suggestions.length) answer("typed", mine.fixed); break;
    case "j": case "n": case "ArrowDown": go(at + 1); break;
    case "k": case "p": case "ArrowUp": go(at - 1); break;
    case "u": nextUnanswered(); break;
    case "m": mode = "mark"; render(); break;
    case "Backspace": case "Delete": {
      if (!mine || mine.text == null) break;
      // Two presses: one stray key never erases typed gold.
      if (clearing === clip.id) answer(null, null);
      else { clearing = clip.id; render(); }
      return true;
    }
    default: return false;
  }
  return true;
}

document.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey || clips.length === 0) return;
  if (busy) return event.preventDefault();
  // A held key would answer clip after clip unheard; only seeking repeats.
  if (event.repeat && mode !== "edit" && !event.key.startsWith("Arrow")) return event.preventDefault();
  const wasClearing = clearing;
  const handled = mode === "edit" ? editKeys(event) : mode === "mark" ? markKeys(event) : normalKeys(event);
  if (clearing === wasClearing && clearing !== null) {
    clearing = null;
    render();
  }
  if (handled) event.preventDefault();
});

document.addEventListener("click", (event) => {
  const span = event.target.closest(".words span[data-word]");
  if (span) toggleMark(span.parentElement.dataset.model, Number(span.dataset.word));
  if (event.target.id === "play") togglePlay();
});

async function start() {
  try {
    const response = await fetch("/api/state", { headers: keyed() });
    if (!response.ok) throw new Error(`${response.status}`);
    const state = await response.json();
    clips = state.clips;
    answers = state.answers;
    const resume = clips.findIndex((c) => c.id === state.position);
    const first = clips.findIndex((c) => !answers[c.id] || answers[c.id].text == null);
    at = resume >= 0 ? resume : Math.max(0, first);
  } catch {
    fail("Could not load the review. Open it with scripts/test-set.sh review, which opens a new page each run.");
    return;
  }
  render();
  if (clips.length) load();
}

start();
