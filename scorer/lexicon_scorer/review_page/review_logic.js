// The gold review page's pure parts: where A and B differ, where a fix starts,
// what each key does and how long is left. No DOM, so the scorer's tests run
// them under osascript's JavaScript; review.js draws the page with them.
"use strict";

const key = (word) => word.toLowerCase().replace(/’/g, "'").replace(/[^\p{L}\p{N}']/gu, "");

// Which words of a and b are not in their longest common subsequence: where
// the two texts differ. A token with no letters or digits (a lone dash) is
// punctuation, which never counts. `first` is the index in b where they first
// part, -1 when they never do.
function differing(a, b) {
  const wa = a.map((w, i) => i).filter((i) => key(a[i]) !== "");
  const wb = b.map((w, i) => i).filter((i) => key(b[i]) !== "");
  const found = differingWords(wa.map((i) => key(a[i])), wb.map((i) => key(b[i])));
  return {
    parakeet: new Set([...found.a].map((i) => wa[i])),
    wispr: new Set([...found.b].map((i) => wb[i])),
    first: found.first < 0 ? -1 : found.first < wb.length ? wb[found.first] : b.length,
  };
}

function differingWords(ka, kb) {
  const n = ka.length, m = kb.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--)
    for (let j = m - 1; j >= 0; j--)
      lcs[i][j] = ka[i] === kb[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  const da = new Set(), db = new Set();
  let i = 0, j = 0, first = -1;
  const part = () => { if (first < 0) first = j; };
  while (i < n && j < m) {
    if (ka[i] === kb[j]) { i++; j++; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { part(); da.add(i++); }
    else { part(); db.add(j++); }
  }
  if (i < n || j < m) part();
  while (i < n) da.add(i++);
  while (j < m) db.add(j++);
  return { a: da, b: db, first };
}

// What "Neither" opens: B's text, which has the punctuation and capitals, with
// the first word that differs selected, since that is usually the one to
// retype. Where B is missing a word A has, the caret sits where it would go.
function prefill(clip) {
  const text = clip.wispr;
  const spans = [...text.matchAll(/\S+/g)].map((m) => [m.index, m.index + m[0].length]);
  const diff = differing(clip.words.parakeet, clip.words.wispr);
  if (diff.first < 0 || diff.first >= spans.length) return { text, start: text.length, end: text.length };
  const [start, end] = spans[diff.first];
  return { text, start, end: diff.wispr.has(diff.first) ? end : start };
}

// Where D plays from, in seconds: just before each place A and B differ, in
// either text. There are no word timings, so a place is estimated from its
// word's share of the text, and two places under a second apart are one.
function differenceTimes(clip, duration) {
  const diff = differing(clip.words.parakeet, clip.words.wispr);
  const places = ["parakeet", "wispr"].flatMap((model) => {
    const list = [...diff[model]].sort((x, y) => x - y);
    return list.filter((i, k) => k === 0 || list[k - 1] !== i - 1)
      .map((i) => ({ model, word: i, time: Math.max(0, (i / clip.words[model].length) * duration - 1.5) }));
  }).sort((x, y) => x.time - y.time);
  return places.filter((p, k) => k === 0 || p.time - places[k - 1].time >= 1);
}

// Keys when no box is open. Letters work with Caps Lock or Shift on too.
const KEYS = {
  " ": "play", a: "pickA", b: "pickB", n: "neither", d: "difference",
  j: "next", ArrowDown: "next", k: "previous", p: "previous", ArrowUp: "previous", u: "unanswered",
  r: "replay", ArrowLeft: "back", ArrowRight: "forward", "[": "slower", "]": "faster",
  1: "fixFromA", e: "edit", f: "fixTerms", m: "mark", Backspace: "clear", Delete: "clear",
};

function command(eventKey) {
  const k = eventKey.length === 1 ? eventKey.toLowerCase() : eventKey;
  return Object.hasOwn(KEYS, k) ? KEYS[k] : null;
}

// A rough guess from how long this session's answers took (the median, so a
// break doesn't swing it), or 20 s a clip before there are any.
function timeLeft(remaining, seconds) {
  if (remaining <= 0) return "all done";
  const sorted = [...seconds].sort((x, y) => x - y);
  const pace = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 20;
  let minutes = Math.round((remaining * pace) / 60);
  if (minutes < 1) return "under a minute left";
  if (minutes < 60) return `about ${minutes} min left`;
  minutes = Math.round(minutes / 5) * 5;
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return m ? `about ${h} h ${m} min left` : `about ${h} h left`;
}
