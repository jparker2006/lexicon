// Gold review page. Talks only to the server that served it
// (scorer/lexicon_scorer/review.py); its Content-Security-Policy refuses anything
// else. The pure parts (differing, prefill, differenceTimes, command, timeLeft)
// are in review_logic.js, loaded first.
"use strict";

const MODELS = ["parakeet", "wispr"];
const LABEL = { parakeet: "A", wispr: "B", typed: "fixed" };
const RATES = [0.75, 1, 1.25, 1.5, 1.75, 2];
const TOUR = [
  "Each clip plays when it opens. Space plays or pauses it, and D plays the part where A and B differ.",
  "Pick the words you actually said, word for word, not what you meant to write. " +
    "Punctuation and capitals don't matter. Press A or B.",
  "Neither right? Press N, fix the highlighted word and press Enter. " +
    "Every answer saves itself, so you can stop any time.",
];

let clips = [];
let answers = {};
let at = 0;
let mode = "normal"; // normal | edit | mark | tour
let tourStep = 0;
let cursor = { model: "parakeet", word: 0 };
let rate = 1;
let error = "";
// An answer or mark is being saved (a few ms): keys pressed meanwhile are
// dropped, so a quick second key never lands on the wrong clip or undoes the first.
let busy = false;
let moves = Promise.resolve();
let clearing = null; // the clip whose answer one Backspace asked to clear
let difference = -1; // which difference D last jumped to, on this clip
// Seconds each answer took this session, for the time left; a long break
// counts as two minutes.
const paces = [];
let since = Date.now();
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

// Before the first key press or click the browser may refuse to play; the
// Play button then says to press Space.
function play() {
  audio.play().then(() => $("play").classList.remove("nudge"), () => {
    $("play").classList.add("nudge");
    $("play-label").textContent = "Press Space to play";
  });
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
    if (mode !== "tour") play();
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
  if (!audio.paused) $("play").classList.remove("nudge");
  if (!$("play").classList.contains("nudge")) $("play-label").textContent = audio.paused ? "Play" : "Pause";
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
  if (choice !== null) {
    paces.push(Math.min(120, (Date.now() - since) / 1000));
    since = Date.now();
  }
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

function edit(text, start = text.length, end = start) {
  mode = "edit";
  render();
  const box = $("typed");
  box.value = text;
  box.focus();
  box.setSelectionRange(start, end);
}

function neither() {
  const fix = prefill(clips[at]);
  edit(fix.text, fix.start, fix.end);
}

// The tour: three steps on the first clip, until Jake finishes or skips it once.

function tour(step) {
  if (step >= TOUR.length) {
    mode = "normal";
    call("/api/toured", {}).catch(() => {}); // at worst it shows again next time
    render();
    since = Date.now();
    play();
    return;
  }
  tourStep = step;
  render();
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
  $("where").textContent = `Clip ${at + 1}`;
  $("progress").textContent = `${done}/${clips.length} answered`;
  $("left").textContent = timeLeft(clips.length - done, paces);
  $("done").style.width = `${(100 * done) / clips.length}%`;
  $("rate").textContent = rate === 1 ? "" : `${rate.toFixed(2)}x`;
  document.body.classList.toggle("marking", mode === "mark");
  $("marking").hidden = mode !== "mark";

  const diff = differing(clip.words.parakeet, clip.words.wispr);
  for (const model of MODELS) {
    const row = $(`row-${model}`);
    words(row.querySelector(".words"), model, clip.words[model], diff[model], mine.marks[model] || []);
    row.classList.toggle("picked", mine.choice === model);
    row.classList.toggle("cursor", mode === "mark" && cursor.model === model);
    $(`pick-${model}`).classList.toggle("chosen", mine.choice === model);
  }
  $("neither").classList.toggle("chosen", mine.choice === "typed");
  $("same").hidden = diff.first >= 0;

  $("wispr-final").textContent = clip.wispr_final || "(nothing)";
  const fixed = clip.jake_edit != null && clip.jake_edit.trim() !== "" && clip.jake_edit !== clip.wispr_final;
  $("edit-line").hidden = !fixed;
  $("jake-edit").textContent = fixed ? clip.jake_edit : "";
  const spellings = MODELS.flatMap((m) => clip.suggestions[m]).map((s) => `${s.found} → ${s.written}`);
  $("lexicon-line").hidden = spellings.length === 0;
  $("lexicon").textContent = [...new Set(spellings)].join(", ");

  $("answer").hidden = mine.text == null || mode === "edit";
  $("choice").textContent = mine.choice ? LABEL[mine.choice] : "";
  const gold = $("gold-text");
  gold.className = mine.text === "" ? "empty" : "";
  gold.textContent = mine.text === "" ? "(nothing said)" : mine.text || "";

  const warn = $("warning");
  const suggest = mine.text != null && mine.suggestions && mine.suggestions.length > 0;
  warn.hidden = !suggest || mode === "edit";
  warn.textContent = suggest
    ? `Your answer has ${mine.suggestions.map((s) => `“${s.found}” where the Lexicon writes “${s.written}”`).join(", ")}. ` +
      "Press F to use the Lexicon's spelling, or J to keep yours and go on."
    : "";
  if (clearing === clip.id) {
    warn.hidden = false;
    warn.textContent = "Press Backspace again to clear this answer.";
  }

  $("editor").hidden = mode !== "edit";
  $("tour").hidden = mode !== "tour";
  if (mode === "tour") {
    $("tour-step").textContent = `${tourStep + 1} of ${TOUR.length}`;
    $("tour-text").textContent = TOUR[tourStep];
    $("tour-next-label").textContent = tourStep + 1 < TOUR.length ? "Next" : "Start";
  }
  const pointed = document.querySelector(".words span.at");
  if (pointed) pointed.scrollIntoView({ block: "nearest" });
}

// Keys

function seek(seconds) {
  audio.currentTime = Math.max(0, Math.min((audio.duration || 0), audio.currentTime + seconds));
}

// Plays from just before the next place A and B differ, so a long clip need not be heard whole.
function nextDifference() {
  if (!Number.isFinite(audio.duration)) return;
  const places = differenceTimes(clips[at], audio.duration);
  if (places.length === 0) return;
  difference = (difference + 1) % places.length;
  const place = places[difference];
  audio.currentTime = place.time;
  play();
  const word = $(`row-${place.model}`).querySelector(`[data-word="${place.word}"]`);
  if (word) word.scrollIntoView({ block: "nearest" });
}

function setRate(step) {
  const i = Math.max(0, Math.min(RATES.length - 1, RATES.indexOf(rate) + step));
  rate = RATES[i];
  audio.playbackRate = rate;
  render();
}

function togglePlay() {
  if (audio.paused) play();
  else audio.pause();
}

function markKeys(event) {
  const clip = clips[at];
  const size = clip.words[cursor.model].length;
  const k = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  switch (k) {
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

function tourKeys(event) {
  if (event.key === "Escape") tour(TOUR.length);
  else if (event.key === "Enter" || event.key === " " || event.key === "ArrowRight") tour(tourStep + 1);
  else if (event.key === "ArrowLeft") tour(Math.max(0, tourStep - 1));
  return true; // nothing else happens under the tour
}

function run(name) {
  const clip = clips[at];
  const mine = answers[clip.id];
  switch (name) {
    case "play": togglePlay(); break;
    case "difference": nextDifference(); break;
    case "replay": audio.currentTime = 0; play(); break;
    case "back": seek(-2); break;
    case "forward": seek(2); break;
    case "slower": setRate(-1); break;
    case "faster": setRate(1); break;
    case "pickA": answer("parakeet", null); break;
    case "pickB": answer("wispr", null); break;
    case "neither": neither(); break;
    case "fixFromA": edit(clip.parakeet); break;
    case "edit": if (mine && mine.text != null) edit(mine.text); else neither(); break;
    case "fixTerms": if (mine && mine.fixed != null && mine.suggestions.length) answer("typed", mine.fixed); break;
    case "next": go(at + 1); break;
    case "previous": go(at - 1); break;
    case "unanswered": nextUnanswered(); break;
    case "mark": mode = "mark"; render(); break;
    case "clear": {
      if (!mine || mine.text == null) break;
      // Two presses: one stray key never erases typed gold.
      if (clearing === clip.id) answer(null, null);
      else { clearing = clip.id; render(); }
      break;
    }
  }
}

document.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey || clips.length === 0) return;
  if (busy) return event.preventDefault();
  // A held key would answer clip after clip unheard; only seeking repeats.
  if (event.repeat && mode !== "edit" && !event.key.startsWith("Arrow")) return event.preventDefault();
  // A clicked button or toggle keeps focus, and Space or Enter would press it again.
  if (mode !== "edit" && document.activeElement !== document.body) document.activeElement.blur();
  const wasClearing = clearing;
  let handled;
  if (mode === "tour") handled = tourKeys(event);
  else if (mode === "edit") handled = editKeys(event);
  else if (mode === "mark") handled = markKeys(event);
  else {
    const name = command(event.key);
    if (name) run(name);
    handled = name !== null;
  }
  if (clearing === wasClearing && clearing !== null) {
    clearing = null;
    render();
  }
  if (handled) event.preventDefault();
});

const BUTTONS = {
  play: "play", difference: "difference", "pick-parakeet": "pickA", "pick-wispr": "pickB", neither: "neither",
};

document.addEventListener("click", (event) => {
  if (clips.length === 0) return;
  if (mode === "tour") {
    if (event.target.closest("#tour-next")) tour(tourStep + 1);
    else if (event.target.closest("#tour-skip")) tour(TOUR.length);
    return;
  }
  const button = event.target.closest("button[id]");
  if (button && BUTTONS[button.id] && !busy) {
    // Neither while its box is open would throw away what is typed. Play and D
    // keep the box open, so Jake can listen again while he types.
    if (mode !== "edit" || button.id !== "neither") run(BUTTONS[button.id]);
    if (mode === "edit") $("typed").focus();
    return;
  }
  // Words are marked only in mark mode, so a stray click never marks one.
  const span = event.target.closest(".words span[data-word]");
  if (span && mode === "mark") toggleMark(span.parentElement.dataset.model, Number(span.dataset.word));
});

async function start() {
  let toured = true;
  try {
    const response = await fetch("/api/state", { headers: keyed() });
    if (!response.ok) throw new Error(`${response.status}`);
    const state = await response.json();
    clips = state.clips;
    answers = state.answers;
    toured = state.toured;
    const resume = clips.findIndex((c) => c.id === state.position);
    const first = clips.findIndex((c) => !answers[c.id] || answers[c.id].text == null);
    at = resume >= 0 ? resume : Math.max(0, first);
  } catch {
    fail("Could not load the review. Open it with scripts/test-set.sh review, which opens a new page each run.");
    return;
  }
  if (clips.length && !toured) mode = "tour";
  render();
  if (clips.length) load();
}

start();
