# Decisions

The one record of what has been decided since the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)) was published, about the product and about how we work. Where this file disagrees with the spec body or its first comment, this file wins, and code, `docs/architecture.md` and open tickets follow it. The spec's first comment (its supersessions, parts 2 and 3) seeded this file and is no longer edited.

## How an entry is written

- **Changed in the same PR as the behavior.** A PR that departs from the spec or from an entry here changes this file in the same PR, or links the entry that already allows it. A PR body that names a departure ("departs from", "supersedes", "Jake's call") links its entry. `scripts/pr-body-check.mjs` refuses "departs from", "deviates" and "unlike the spec" with no link to this file; "supersedes" and "Jake's call" are #226.
- **Each decided entry carries Jake's own words, verbatim, the question as he was asked it, and the time** (UTC). His words are quoted from the session where he answered; the link is the GitHub record of the question or the decision.
- **An entry without Jake's words is Proposed.** It stands as built, and it goes into the next grill round, where the orchestrator asks Jake to confirm or change it. Nobody writes "Jake's call" for a choice he didn't make.
- **A fact is not a decision.** A corrected number or a found behavior is recorded as a fact and applied; a change of what Lexicon does is a decision and goes to Jake.
- **Replaced entries move to [Replaced](#replaced),** naming what replaced them. New entries are numbered from 61, on the day they are decided.

## Current: how we work

### The M0 retro grill (#88, 2026-10-12)

The orchestrator asked 19 questions in four rounds, each with its recommendation, from 04:21:18Z; Jake took every recommendation. The record on GitHub is the [#88 checklist](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6117824606), with Q3 in full [here](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6118799341). Jake's answers:

- Round 1 (Q1 to Q5), 04:23:43Z: "Q1 A or B / Q2 recs fine / Q3-5 recs goos"
- Q1 again, and round 2 (Q6 to Q10), 04:25:38Z: "Q1 A, recs for all, 11am and 6pm but liek not locked in on that one im lowk fine going hands free id rather go hands free tha have to do stuff"
- Round 3 (Q11 to Q15), 04:26:37Z: "recs for all"
- Round 4 (Q16 to Q19), 04:29:41Z: "recs for all"
- The three yes-or-no questions and the ticket list, 04:31:43Z: "publish, yes to all three"

**Q1. Approvals reach the session that acts.**
> Q1, relayed approvals: sessions refuse a "Jake said yes" relayed by me, so you typed things twice. Options: (a) your yes goes either into the chip you click, with its exact scope, or gets typed by you in the session that asks, and I tell you which session to answer in; (b) sessions accept my relay; (c) you type every approval in the acting session. ➡️ (a)

After "A or B", the orchestrator recommended A "plus a standing install rule in the new Reviewer's starting prompt", for example "install main after each M1 wave once its live items pass", and Jake answered "Q1 A". Decided: (a), and standing approvals go in each fresh session's start prompt, including the Reviewer's install rule. Lives in AGENTS.md, Ask Jake first.

**Q2. One settings ask.**
> Q2, the settings change: several fixes live in `.claude/settings.json`: run Bash in bash, turn fast mode off, block reads of your private folders, allow the review Workflow. Auto mode only lets an agent edit that file on your yes in its own session. Options: (a) one builder asks you once with the full list; (b) you apply it yourself; (c) one ask per setting. ➡️ (a)

Decided: (a). Done in #154.

**Q3. Standing approvals.**
> Q3, standing approvals: a dated list in CLAUDE.md of things I just do without asking: post chips for unblocked tickets, up to the builder cap and while the plan is under 90% of the 5-hour window and 95% of the week; remove worktrees of merged PRs; archive finished sessions. It still asks for anything private, any spend, any other deletion, and next-milestone work. Yes, or keep asking each time? ➡️ Yes

Decided: yes. Lives in CLAUDE.md, Standing approvals.

**Q4. A standing opt-in for review Workflows and swarms.**
> Q4, a standing opt-in for review Workflows and swarms: builders and the Reviewer run the checked-in review Workflow on every PR (a critic per lens, a verifier per finding), plus swarms for jobs with 10 or more similar pieces, on Haiku and on the plan only. Only 2 builders did this in M0, and they produced 47 of the 64 verifiers. ➡️ Yes

Decided: yes. Lives in CLAUDE.md, Standing Workflow opt-in, and the Reviewer's start prompt.

**Q5. One asker.**
> Q5, one asker: only I ask you decisions, in one numbered round with a recommendation each. Physical asks come only from Live checks. Other sessions post their question on their issue and wait. ➡️ Yes

Decided: yes. Lives in workflow.md, Roles.

**Q6. Jake's hands gate the install, not the merge.**
> Q6, what waits for your hands: the merge or the install? Live-checked PRs averaged 163 minutes from PR to merge, against 42 for headless ones, mostly waiting for your next break. (a) A PR merges on its headless checks plus the hands-off live checks. Your physical items get checked on main in the next sitting, and nothing installs on your daily copy until they pass. (b) Every live item gates the merge, as today. ➡️ (a). Your daily app still never gets anything you haven't checked, and main stops waiting on your breaks.

Decided: (a). Lives in workflow.md, Live checks, and review.md, Risk tiers.

**Q7. Sittings.**
> Q7, scheduled sittings: at most two a day, about 15 minutes each, at times you pick. Each is one numbered checklist with the total minutes up front. Nothing physical comes outside a sitting, and you're never asked "done?" when the log can already see the result. ➡️ Yes. Which two times work? For example 11 AM and 6 PM.

Decided: yes, at most two a day, by default 11 AM and 6 PM Pacific and not fixed, and a sitting only when something truly needs his hands: "id rather go hands free tha have to do stuff". Lives in workflow.md, Live checks.

**Q8. Live checks quits and reopens the daily app around a sitting.**
> Q8, your daily Lexicon during sittings: Live checks quits your daily app from its menu at the start of a sitting (only when no Dictation is in progress) and reopens it at the end. It never force-kills it and never touches its data or permissions. ➡️ Yes. One fewer step for you each time.

Decided: yes. Lives in AGENTS.md, Dev builds and the live app, and workflow.md, Live checks.

**Q9. Mac habits and the lag bar's power state.**
> Q9, Mac habits: (a) Keep the Mac awake while sessions run? I'd ask the app for it and release it when things go idle. A closed lid still sleeps. (b) Keep Low Power Mode off during builds? You just did. A script will warn if it's on. (c) Which power state counts for the lag bar? ➡️ (a) yes; (b) yes; (c) whatever state you normally dictate in, with the other one reported alongside.

Decided: all three. This settles spec item 60. Lives in workflow.md, Concurrency and Live checks, and architecture.md, Budgets.

**Q10. No second live lane yet.**
> Q10, a second live lane: two Lexicons on one Mac fight over fn, focus and the clipboard (that's what caused #141), so a second lane would mean a macOS virtual machine, which is untested. (a) Not now: the new test hooks take most of M1's key checks off your hands. Revisit after M1 wave 1. (b) Try a VM now, time-boxed. ➡️ (a)

Decided: (a), revisited after M1 wave 1.

**Q11. Tickets close at merge, with a Try list.**
> Q11, closing tickets: merged tickets stayed open for you to try, so their dependents looked blocked, and I closed about 31 by hand. (a) Every ticket closes when its PR merges. Things to try go on one pinned "Try list" issue that each install updates, and you tick items off after you use them. (b) Keep them open as today. ➡️ (a)

Decided: (a). Lives in workflow.md, The loop step 8; `scripts/merge-pr.mjs` and `scripts/install.sh` do it.

**Q12. Decisions live in this file.**
> Q12, where decisions live: 33 spec changes in M0 never reached the spec. (a) A `docs/DECISIONS.md` in the repo, updated in the same PR as the behavior change, with your words and a link to the question, and #36 points to it. (b) I edit #36's supersessions comment by script whenever something is decided. ➡️ (a). It's reviewed and versioned, and builders already read the repo.

Decided: (a), this file.

**Q13. Review notes become `later` issues.**
> Q13, review notes: the Later list is one long comment with no owners, and 7 merged PRs carry a known defect with no ticket. One example: Cleanup drops the first "twenty" in "twenty twenty six". (a) Every non-blocking review note becomes an issue labelled `later`, and you triage the queue once per milestone. (b) Keep the Later comment that you promote by hand. ➡️ (a). This replaces your rule about promoting Later items yourself, so it's your call.

Decided: (a). Lives in review.md and triage-labels.md.

**Q14. A milestone's finish line freezes.**
> Q14, freezing a milestone's finish line: a milestone's gate list freezes when its last planned ticket starts. A new find joins only if it loses a Dictation or damages your text or data, and only with your one-line yes. Everything else goes to the next milestone. ➡️ Yes. This is the fix for the churn.

Decided: yes. Lives in workflow.md, The loop.

**Q15. One-click chips, posted per wave.**
> Q15, starting builders: (a) keep one-click chips, but post each wave's chips together, so you click them all in one go. (b) Also try a `/build-wave` command that starts a whole wave with no chips. ➡️ (a) now. Try (b) only if clicking still feels like a chore after wave 1.

Decided: (a). Lives in workflow.md, The loop step 4.

**Q16. Gold review order: held-back clips first, then session order, with partial scores.**
> Q16, order and sittings: (a) Start with the held-back sessions: 56 clips, about 26 minutes, and that finishes the pass-mark set. Then do everyday sessions in a fixed shuffled order, about 20 minutes per sitting. Scores count only fully answered recording sessions, so you can stop after any session and partial scores are still valid. (b) Quickest clips first. (c) The current order. ➡️ (a)

Decided: (a). Built in #155.

**Q17. Spot-check the agreed clips.**
> Q17, spot-check the agreed clips: the 210 clips where both models agree become gold with no listening. If both mishear the same tech word, that error becomes "truth" and the Terms score can't see it. (a) After the 250, about 60 agreed clips that contain a Term join the review page, about 28 more minutes. (b) No audit. ➡️ (a). That's the evidence behind "beats Wispr".

Decided: (a).

**Q18. Keep mark mode.**
> Q18, mark mode: marking wrong words saves them, but nothing reads the marks yet. (a) Keep it, have #86 (M4) read the marks later, and fix #51's wording to match. (b) Delete it. ➡️ (a)

Decided: (a). #86 reads the marks.

**Q19. A 10-item trial for any long task.**
> Q19, trials for long tasks: the gold page was too busy on first use, and its time estimate was 3 to 5 times too low. (a) Any task that needs more than 15 minutes of your time ships only after a 10-item trial run with you, with the estimate based on real counts times your measured pace. (b) No trial. ➡️ (a)

Decided: (a). Lives in workflow.md, Human time.

**61. No number measured on Jake's Wispr history goes on GitHub.**
> Numbers on GitHub: a rule that public text never carries anything measured from your own Wispr history, while Test set sizes and scores are allowed? ➡️ yes

Jake, 04:31:43Z: "publish, yes to all three". The second question was about the old public text: "#19 to #22 and the #36 body carry a few totals derived from your Wispr history. Rewrite them to remove those?", also yes. The orchestrator removed those totals, and `docs/architecture.md` lost its Wispr lag figures with this file. Lives in AGENTS.md, Private data.

**62. The Reviewer uses Workflows and swarms, as a standing rule.** Not asked: Jake raised it himself, 2026-10-12 06:29:41Z, after telling the Reviewer to use Workflows and swarms: "we should make that a rule in our workflow though". The details are the orchestrator's, written on [#162](https://github.com/jparker2006/lexicon/issues/162#issuecomment-6119007942), and are Proposed until Jake confirms them: in parallel, not in a line; the full review Workflow on high-tier PRs and a light pass on low-tier ones; every blocker in the first verdict; the opt-in carried in the start prompt. Lives in review.md, The Reviewer's duties.

### Earlier, while M0 was built (2026-10-11)

**63. Builder sessions: up to 8.**
> Q2 - Builders at once: up to 8, only one at a time on the live app (fn, mic, paste), a shared build cache, and worktrees deleted after merge. ➡️ Yes. We can raise it to 10 once disk space and the CI queue hold up.

Jake, 2026-10-11 05:24:13Z: "Q2 up to 8 and see how it is at 8". Lives in workflow.md, Concurrency, where `scripts/machine.sh` also has to say there is room.

**64. The plan only: no fast mode, no usage credits.** The orchestrator proposed a one-ticket fast-mode trial with usage credits and a spending cap. Jake, 2026-10-11 09:42:07Z: "Ohh na no fast mode if its not on the subscription lol." `.claude/settings.json` turns fast mode off. Lives in AGENTS.md, Ask Jake first.

### Proposed (stands as built, for the next grill round)

**65. The merge rule.** The Reviewer runs `gh pr update-branch` only on the PR it is about to merge, then waits for CI on that exact head; builders bring `main` in only to resolve a conflict. The orchestrator's call, shown to Jake at 2026-10-12 04:21:18Z under "Calls I made for you (say if you disagree)"; he raised none, which is not a yes. Built in `scripts/merge-pr.mjs` (#159).

**66. Two build slots, and builders added while the Mac has room.** Heavy jobs take turns in two slots, and builder sessions start at about 4 to 6 and step up while `scripts/machine.sh` says there is room. The orchestrator's call, shown to Jake in the same message as 65.

**67. What a `// timing-ok:` line covers.** Besides a real-time deadline that only bounds a hang, the timing lint (`scripts/checks/20-test-timing.sh`) accepts a `// timing-ok:` disclosure on the line for: a poll interval, a kill moment that is the test's own input, a semaphore the test itself releases, and a cancellation-only stand-in. The Reviewer's ruling in its verdict on PR #211 (#160).

**69. Only the orchestrator posts chips.** Proposed. Jake, 2026-10-12 09:49:04Z, not asked: "sometimes builders give me chips to spin up...". The orchestrator answered with the rule and wrote it on [#162](https://github.com/jparker2006/lexicon/issues/162#issuecomment-6121815026): a builder, the Reviewer or Live checks files out-of-scope work with `scripts/ticket.sh later` and names it in its Ready line, and the orchestrator decides whether and when it becomes a chip. Lives in AGENTS.md, Doing the work, and workflow.md, Roles.

## Current: the product (spec part 3)

Items 25 to 60 come from the spec's first comment, part 3, "what building M0 changed". Each says what the spec said, what was built, and who decided.

### Decided by Jake

**25. Race cutoff.** Spec: the cloud wins only if its final arrives within 300 ms after recording stops; otherwise local wins. Built: the cloud is preferred for 300 ms after recording stops; after that the first engine to answer wins, so a cloud final at 400 ms beats a local model still loading. A local answer still waits up to 300 ms for the cloud. Shipped in PR #127 (merged 2026-10-11 14:12Z), then asked:
> Race rule: keep #66's version, where after 300 ms the first answer to arrive wins.

Jake, 14:24:29Z: "rec for both" (this and item 33). Recorded on [#66](https://github.com/jparker2006/lexicon/issues/66#issuecomment-6110021565).

**26. A missed paste stays on the clipboard about 2 s.** Spec (story 26): never put text on the clipboard behind Jake's back; restore with an 8 s cap. Built: a paste no app reads within 1 s is "not inserted"; the text stays up until 2 s after the write, then Jake's clipboard comes back if nothing else changed it, so a Cmd-V still in flight never pastes his previous clipboard. The one exception to story 26. Asked by the Reviewer ([PR #119](https://github.com/jparker2006/lexicon/pull/119#issuecomment-6108583337)):
> After a missed paste, the Dictation stays on your clipboard for up to 8 s. [...] I recommend keeping a short hold, about 2 s, as the one documented exception.

Jake, in the Reviewer's session, 2026-10-11 11:34:45Z: "go with both recommendations idrk what that means" (this and item 27). Recorded on [#54](https://github.com/jparker2006/lexicon/issues/54#issuecomment-6108594229). His words say he didn't follow the question, so the next grill round puts items 26 and 27 to him again in plain words.

**27. Clipboard access denied: no automatic paste.** Spec: silent. Found: macOS 26 has a "Paste from Other Apps" permission. Built: if Jake denies it, a Dictation is not pasted; it lands "not inserted" (reason: clipboard denied) with a notice and waits for ⌃⌘V, because Lexicon never replaces a clipboard it can't save. Asked in the same comment as 26:
> If you deny macOS's new "Paste from Other Apps" prompt, Lexicon can't save your clipboard, so every Dictation would replace it. I recommend that if access is denied, Lexicon doesn't paste at all: it keeps the text for ⌃⌘V and shows a notice.

Jake: as item 26.

**28. ⌃⌘V with clipboard access denied still pastes.**
> When the permission is denied and you press ⌃⌘V, what should happen? A: Paste anyway. This replaces your clipboard and doesn't put the old one back, since Lexicon can't save it. You pressed ⌃⌘V yourself, so it isn't behind your back. B: Block it, as #54 does now. ➡️ A.

Jake, 2026-10-11 11:53:43Z: "rec, go with A". Recorded on [#54](https://github.com/jparker2006/lexicon/issues/54#issuecomment-6108742707). The paste path is on main (`TargetApp.pasteLast`); #62 wires the key.

**29. M0's offline check: zero network connections instead of wifi off.** Spec (#56): hold fn in four apps with wifi off. Built: wifi stayed on, and Live checks sampled Lexicon Dev's sockets for the whole run, all zero. Jake, 2026-10-11 12:38:43Z: "yeah lets do 56, but i dont feel like turning off my wifi lmao". Recorded in the [#56 Live checks result](https://github.com/jparker2006/lexicon/issues/56#issuecomment-6109845672). **M0 only:** from M2 the cloud is in play, and #79 requires a real wifi-off run.

**30. Cold mic start.** Spec: fn-down to first audio 60 ms or less, cold and after `prepare()`. Built: prepared starts take 31 to 45 ms; cold starts 74 to 212 ms, which AVAudioEngine can't beat. The app stays prepared, so cold happens only on a tail cut by a new fn-down or the first Dictation after a mic grant.
> Cold mic start is slower than the target. [...] ➡️ Accept it. History logs the start gap, so we'll see if cold starts ever matter.

Jake, 2026-10-11 10:43:22Z: "Q1 yeah its fine". Recorded on [PR #115](https://github.com/jparker2006/lexicon/pull/115#issuecomment-6108191844). The 60 ms budget now means the prepared path (architecture.md Budgets). Quiet-Mac rerun on #56, 2026-10-12: first audio p50 36 ms, p95 44 ms, prepared every time.

**31. No AirPods check.** Spec: measure on the built-in mic and on AirPods. Built: built-in mic only; the device-change code stays.
> AirPods weren't tested, because none were connected. [...] Test them when you have AirPods handy [...] Or skip it until you notice something wrong in daily use.

Jake, 10:43:22Z, same message: "Q2 i dont even really use airpods i only use the default mi". Recorded on PR #115, as item 30.

**32. Gold is what Jake said, word for word.** Spec: "a word-for-word gold of what Jake said" for words heard right. Built: the review page (#51, simplified in #128) asks for said text only; "what he meant" comes from his own Wispr edits plus a short pass in M3 on clips where those are missing.
> Should the page also ask for "what I meant"? A: said-only. [...] B: add an optional "meant" box [...] ➡️ A for now.

Jake, 2026-10-11 12:38:01Z: "no i mean said only for now." Recorded on [#51](https://github.com/jparker2006/lexicon/issues/51#issuecomment-6109102323).

**33. The starter Lexicon goes into the daily app at install.** Spec: a private import file that dev builds and `lexicon-eval` load. Built: the Reviewer imports it into Jake's daily copy as part of an install and reports counts only; it is never written into Lexicon Dev's data.
> Starter Lexicon: import it into your daily app at install, not the test app.

Jake, 2026-10-11 14:24:29Z: "rec for both". Recorded on [#71](https://github.com/jparker2006/lexicon/issues/71#issuecomment-6110021910).

**57. Retry keeps the previous version.**
> Q2: Retry keeps no earlier text. Retry replaces the text, so a Fix you made on the old version is lost. ➡️ Rec: keep the previous version, so you can go back to it.

Jake, 2026-10-12 07:25:54Z: "recs for all" (items 57, 58 and 59). Retry stores the old cleaned and final text as an earlier version, shown in Show Versions, so a Fix on it is not lost. #213 builds it.

**58. A common word stays a code Term when it is a code name in Jake's repos.**
> Q3: Code names that are also dictionary words (#73). The rule "no Terms that are also common words" also drops names like Stripe and Next from Code Terms. ➡️ Rec: keep a dictionary word when it shows up as a code name in your repos (a package, import or file name).

Jake: as item 57. Decided: a package, import or file name in his repos keeps the word. Proposed, from #36's wording of this item, which Jake was not shown: a type name counts too, and prose and comments don't. #73 builds it.

**59. M1 takes Esc and ⌃⌘V with a registered hotkey first.**
> Q1: How M1 blocks Esc and ⌃⌘V (#58, #62). Today Lexicon only listens to keys, so Esc while recording and ⌃⌘V also reach the app in front. Blocking keys the old way added 26 to 74 ms of delay to every key you typed. Options: (a) a registered hotkey for Esc, held only while recording. [...] (b) a key-blocking tap that is on only during a Dictation, with its delay per key measured. Either way, typing delay while Lexicon is idle has to stay at 2 to 12 ms. ➡️ Rec: (a). #58 tests it first and falls back to (b) only if it fails.

Jake: as item 57. #58 spikes the registered hotkey and falls back to (b) only if it fails; #62 uses the same approach. [ADR 0004](adr/0004-listen-only-fn-tap.md).

**60. The lag bar's power state.** Settled by grill Q9 (c): the state Jake normally dictates in, with the other reported beside it. Jake, 2026-10-12 04:25:38Z: "recs for all" (Q6 to Q10).

### Proposed: built on an agent's default, never asked

These stand as built until Jake confirms them as a batch or names items to change, in the next grill round.

**34. The fn tap is listen-only.** Spec: one active, session-level CGEventTap. Built: a listen-only tap, started only when `CGPreflightListenEventAccess()` already reads true (it does with Accessibility alone, so there's no prompt). Measured live: keys reached the focused app 26 to 74 ms late through the active tap (five presses timed), 2 to 12 ms through listen-only. The orchestrator and Reviewer's choice, PR #123; Jake got a heads-up, not a question. Item 59's question, which Jake answered, kept idle typing delay at the listen-only figure. [ADR 0004](adr/0004-listen-only-fn-tap.md).

**35. Sounds are warm on demand.** Spec: an always-warm audio engine. Built: the output engine starts with the Dictation and stops 3 s after its last use (never with Sounds off), because a running output engine stops the Mac from idle-sleeping. Start, stop and warning sounds take 7.7 to 10 ms; a cold cue takes 28 to 35 ms against a 20 ms target. #55's builder; written as "Jake's call" in the Later list without asking him (PR #110).

**36. The local model loads at launch, and fn-up waits at most 2 s for it.** Spec: load on fn-down if not resident. Built: also at launch; a load still running 2 s into fn-up sends the Dictation to waiting (`localModelLoading`) and retries it, because the first load of each new build compiles for about 25 s. #56's builder (PR #129).

**37. The pill and start sound wait for the 0.30 s hold.** Spec: "listening" shows when the first buffer arrives. Built: recording starts at fn-down, but nothing shows or sounds until the hold is confirmed, so fn+arrow chords and stray taps stay silent. #55's builder (PR #110).

**38. Start at login: the daily copy only, once.** Built as the spec for the daily copy, plus: Lexicon Dev never registers itself, and the daily copy registers once, so a login item Jake removes stays removed until he turns it on in Lexicon's menu. A Dev build at login would answer fn beside the daily copy. #57's builder (PR #138).

**39. First-run setup.** Built: four rows (Microphone, Accessibility, Speech model, Try it); the download starts by itself once both permissions are granted, and Private mode stops it; a left click on the warning dot opens the missing step, a right click the menu. The fourth row was the spec's own assumption; the rest #57's builder (PR #138).

**40. Waiting retries.** Built: a retry tick every 30 s; a waiting Dictation is judged by the app it was made in; once Private mode denies its retry, it stays local even after Private mode goes off, because its words are fixed and failing closed is safer. #59's and #68's builders (PR #125, PR #140); the retry cases were shown to Jake as a planning assumption, and the Reviewer listed the rules as "Jake can overrule".

**41. Mic start has a time limit, with one gap.** Built: the engine gets 2 s to start (up to 60 s while the macOS mic prompt waits); after that the Dictation fails with a notice and a History row, and the next fn-down builds on a fresh queue. Gap: words spoken while the macOS mic prompt is up are never captured. Proposed: accept the gap, and have that notice say to speak again. #142's builder and the orchestrator (PR #146).

**42. Text that cleans to nothing is silence.** Built: blank text after Cleanup or a Retry is a failed "silence" row, never an empty Cmd-V; a Retry of a settled row that cleans to blank leaves the row as it was. #145's builder (PR #148).

**43. Chord cancel shipped in M0.** Spec: M1. Built: another key in the first 0.30 s cancels silently, so fn+arrow works from the first build. Decided when #53 was written.

**44. Our own fn state machine, not Hex's code.** Spec: copy Hex's state machine and tests (MIT). Built: a smaller fn-only machine with Hex's test scenarios; no Hex code copied. #53's builder (PR #123).

### Moved to a later milestone

- **45.** Long hands-free Dictations: a 20-minute Dictation waits 25 to 41 s at fn-up (#47); the switch to Parakeet's streaming mode is #117 (M1).
- **46.** Quit and the clipboard restore: quitting right after a paste, or during item 26's 2 s hold, can leave Dictation text on the clipboard. #132 (M1).
- **47.** The "same app and under 5 s" late-text fallback for apps whose field can't be detected: not built. #60 (M1).
- **48.** The audio retention sweep runs at launch only, not on a rolling schedule. No ticket yet.

### Facts the spec got wrong

- **49.** Gold review: 250 clips to review (194 everyday, 56 held back), 117 minutes of audio, against the spec's estimated 100 to 150 clips. About 2 to 2.5 hours at normal speed; the review runs in short chunks (#51).
- **50.** Test set split: 100 held back and 360 everyday (460 clips), not 341 everyday. #78 follows 360.
- **51.** Model download: about 614 MB in code, 595 MB on disk, not 609 MB. Proposed: the spec says about 600 MB, and the exact figure lives in one constant.
- **52.** Launch to fn working, 150 ms: met on warm relaunches (35 to 137 ms), missed on the first launch after an install. Proposed reading, used in architecture.md Budgets and `scripts/bench.sh`: p95 of warm relaunches, with the first launch after an install reported on its own.
- **53.** History open, 100 ms at p95: the quiet-Mac rerun gave p95 127 and 139 ms over 20 opens, a fail; #150 fixes it. Proposed reading, used the same way: p95 over every open, with the first open after launch also reported on its own.
- **54.** Lexicon's own work, fn-up to Cmd-V, 10 ms: cold first pastes measured 7.1 to 14.0 ms (#54), under load. A quiet-Mac recheck is still owed.
- **55.** Memory while dictating, about 160 MB: peak 66 to 68 MB on a 6 s clip, 258 MB on a 20-minute clip (#47). Proposed: keep 160 MB for normal Dictations and measure the 20-minute peak again with #117.

- **68.** The spec lists "`CloudAccess` is the only door to the network" among the compiler-enforced invariants. Only the key is: every cloud key comes through a `CloudAccess`, but the sockets and HTTP calls are plain `URLSession` that would take any request. architecture.md says so; keeping the network behind `CloudAccess` is a review rule (review.md).

Settled since M0, no change: #81's quiet-Mac rerun (2026-10-12) kept Jev's 250 ms budget (warm p50 145 ms, p95 174 ms, 0 of 20 calls over 250 ms).

### Open

**56. The structural check rejects the Term fixes Lexicon exists for.** The spec sends close misses ("super base") to AI cleanup with Terms in context, but its structural check rejects "Supabase" because the heard words are gone. To decide in #75: accept a dropped span that fuzzy-matches an added Term, tuned in the M3 bake-off.

## Current: before M0 (spec part 2)

The spec's own supersessions, written when it was published; each names the planning ticket that decided it, and those tickets hold the questions. They predate the rule that every entry carries Jake's words.

1. **Cloud speech:** Meta Muse streamed over its own WebSocket, not MAI-Transcribe-2 through OpenRouter (no streaming there).
2. **Speech in M0:** local Parakeet only for M0 and M1; Muse lands in M2, which is named "Cloud and Private mode", since offline works from M0.
3. **Race cutoff:** 300 ms after recording stops, not 0.8 s after fn-up. (Item 25 replaced its "otherwise local wins".)
4. **Capture tail:** adaptive, stop on silence, at most 200 ms.
5. **Jev:** TypeSafe direct with `jev-1.13.0` pinned, not through Vercel AI Gateway.
6. **Jev for close calls** is dropped; Jev is for Re-speak and Hand fixes only.
7. **Terms to speech:** up to 50.
8. **Local word boosting:** dropped; Rules in code instead.
9. **Cleanup:** AI cleanup on by default, with a Cleanup deadline of about 450 ms, set so total lag stays within the pass mark; Apple Foundation Models is out for now, so Private mode and offline use rules only.
10. **Fixes to the Test set:** every Re-speak fix becomes a Test set entry at once (Hand fixes follow in M5); when a Fix becomes a Rule is the after-M1 grill.
11. **Head-to-head:** no BlackHole or synthetic fn; Wispr is scored from its own logs.
12. **Wispr's lag:** taken from Wispr's own logs on Jake's Mac, which show it slower than the competitor benchmark's figure and slower than Lexicon's lag target.
13. **Toolchain:** Command Line Tools only and the self-signed "Lexicon Dev" certificate ([ADR 0003](adr/0003-command-line-tools-only.md)).
14. **fn:** the double-tap window is 0.25 s; Fn+Space and the fallback hotkey are dropped from v0.
15. **Sounds:** soft synthesized blips, pitched lower.
16. **Glossary:** Rule means "added by the user or learned from a confirmed Fix"; Lexicon means "Terms and Rules"; Term was added; the Secret guard keeps keys out of text calls and cuts the speech stream, but can't recall audio already sent.
17. **Code context:** names only (repo, dependency, skill and slash-command names, bold glossary terms); no identifiers or file names.
18. **Active-app formatting:** none in v0; moved to the after-M1 grill.
19. **Meaning check:** the structural check, which allows AI cleanup, replaces the research's `verify()`.
20. **Scores:** words heard right and Terms right, plus lag, offline and lost; a quick run after any change to speech or Cleanup, a full held-back run per milestone.
21. **Lag** is measured from fn-up to text on screen.
22. **Insert at the cursor:** late or homeless text doesn't insert; it waits for paste-last.
23. **Jev calls:** one request per state with all its questions; measured warm p50 150 ms, p95 215 ms.
24. **Languages:** English only, with Parakeet Ultra or v3 in the model picker as the multilingual switch.

## Replaced

- **"Otherwise local wins"** at the race cutoff (part 2 item 3), by item 25.
- **"Never put text on the clipboard behind Jake's back", restored within 8 s** (spec story 26), by item 26's 2 s hold, its one exception.
- **One active fn tap** (the spec), by item 34 and ADR 0004.
- **The local model loads on fn-down only** (the spec, ADR 0001), by item 36.
- **60 ms to first audio, cold or prepared** (the spec), by item 30: the budget is the prepared path.
- **Tickets Jake can feel stay open until he closes them** (workflow.md, M0), by Q11.
- **Jake promotes Later items himself** (review.md, M0), by Q13.
- **Every live item gates the merge** (workflow.md, M0), by Q6.
- **Only Jake quits his daily copy** (workflow.md, M0), by Q8.
- **A builder grills its own issue and waits for Jake's OK** (workflow.md, M0), by Q5.
- **gstack's one-time browser download** (the third yes at 04:31:43Z): dropped. Jake, 05:05:43Z, when the orchestrator said agents only reached for gstack because his global CLAUDE.md told them to: "yeah remove the line, rec for both"; then, on cutting the whole gstack section, 05:07:43Z: "yeah cut it". The #88 checklist records the download as dropped because he doesn't use gstack. `.gstack/` stays in `.gitignore`.
