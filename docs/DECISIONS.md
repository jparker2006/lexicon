# Decisions

The one record of what has been decided since the v0 spec ([#36](https://github.com/jparker2006/lexicon/issues/36)) was published, about the product and about how we work. Where this file disagrees with the spec body or its first comment, this file wins, and code, `docs/architecture.md` and open tickets follow it. The spec's first comment (its supersessions, parts 2 and 3) seeded this file and is no longer edited.

## How an entry is written

- **Changed in the same PR as the behavior.** A PR that departs from the spec or from an entry here changes this file in the same PR, or links the entry that already allows it. A PR body that names a departure ("departs from", "supersedes", "Jake's call") links its entry. `scripts/pr-body-check.mjs` refuses "departs from", "deviates" and "unlike the spec" with no link to this file; "supersedes" and "Jake's call" are tracked in #226.
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

**69. Only the orchestrator posts chips.**
> The builder recorded the chips rule in DECISIONS.md as item 69, marked "Proposed": you raised the problem, but nobody asked you to confirm the rule itself. The rule: only the orchestrator posts chips, and other sessions file Later issues instead. Rec: yes.

Jake, 2026-10-12 10:36Z: "yes to the chips rule" ([record](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6122562855)). He had raised the problem at 09:49:04Z ("sometimes builders give me chips to spin up..."). Decided: only the orchestrator posts chips; a builder, the Reviewer or Live checks files out-of-scope work with `scripts/ticket.sh later` and names it in its Ready line, verdict or `Live checks:` result, and the orchestrator decides whether and when it becomes a chip. Lives in AGENTS.md, Doing the work, workflow.md, Roles, the orchestrate, review-merge and live-checks skills, and the orchestrator's start prompt.

**77. Build slots wait in line, with a third slot while the Mac has room.**
> **Decision:** should I file an M1 ticket to fix the slots? It would do two things: 1. Make the wait first-come-first-served. 2. Allow a third slot only while `machine.sh` shows headroom. Builders would wait far less, and M1 finishes sooner. M1's gate isn't frozen yet, since its last planned ticket hasn't started, so it can join M1. A builder takes it when a lane frees. My recommendation is yes. Reply yes to take that, or "just FIFO" if you'd rather keep two slots and only fix the order.

Asked by the orchestrator in its session, with the evidence: 8 builders on 2 slots, #60's test waited 45 min while newer jobs got in, at a load of 0.8 per core. Jake, 2026-10-12, about 13:19Z: "yes" ([record](https://github.com/jparker2006/lexicon/issues/238#issuecomment-6125100225)). It joins M1 because M1's gate list had not frozen yet (Q14), as the question said. Decided: a job that can't take a slot waits in one line shared by every worktree, and only the job at its head takes a free slot; a waiter whose process is gone drops out at once. Slot 3 is taken only when slots 1 and 2 are held and the machine verdict (`scripts/lib/verdict.sh`, the rule `scripts/machine.sh` prints) says yes at that moment; a reading it can't take counts as a no. A quiet timing run waits in the same line, then takes all three slots, slot 1 first: it is one job keeping the Mac quiet, not a third build. A build splits the cores by the slots held. Built in [#238](https://github.com/jparker2006/lexicon/issues/238). Lives in `scripts/lib/heavy.sh`, AGENTS.md, Commands, and workflow.md, Concurrency.

### Earlier, while M0 was built (2026-10-11)

**63. Builder sessions: up to 8.**
> Q2 - Builders at once: up to 8, only one at a time on the live app (fn, mic, paste), a shared build cache, and worktrees deleted after merge. ➡️ Yes. We can raise it to 10 once disk space and the CI queue hold up.

Jake, 2026-10-11 05:24:13Z: "Q2 up to 8 and see how it is at 8". Lives in workflow.md, Concurrency, where `scripts/machine.sh` also has to say there is room.

**64. The plan only: no fast mode, no usage credits.** The orchestrator proposed a one-ticket fast-mode trial with usage credits and a spending cap. Jake, 2026-10-11 09:42:07Z: "Ohh na no fast mode if its not on the subscription lol." `.claude/settings.json` turns fast mode off. Lives in AGENTS.md, Ask Jake first.

### Proposed (stands as built, for the next grill round)

**62. The Reviewer uses Workflows and swarms, as a standing rule.** Proposed. Not asked: Jake raised it himself, 2026-10-12 06:29:41Z, after telling the Reviewer to use Workflows and swarms: "we should make that a rule in our workflow though". The rule and its details are the orchestrator's, written on [#162](https://github.com/jparker2006/lexicon/issues/162#issuecomment-6119007942): in parallel, not in a line; the full review Workflow on high-tier PRs and a light pass on low-tier ones; every blocker in the first verdict; the opt-in carried in the start prompt. Lives in review.md, The Reviewer's duties.

**65. The merge rule.** The Reviewer runs `gh pr update-branch` only on the PR it is about to merge, then waits for CI on that exact head; builders bring `main` in only to resolve a conflict. The orchestrator's call, shown to Jake at 2026-10-12 04:21:18Z under "Calls I made for you (say if you disagree)"; he raised none, which is not a yes. Built in `scripts/merge-pr.mjs` (#159).

**66. Builders added while the Mac has room.** Builder sessions start at about 4 to 6 and step up while `scripts/machine.sh` says there is room. The orchestrator's call, shown to Jake in the same message as 65. Its first half, two build slots, is replaced by item 77.

**67. What a `// timing-ok:` line covers.** Besides a real-time deadline that only bounds a hang, the timing lint (`scripts/checks/20-test-timing.sh`) accepts a `// timing-ok:` disclosure on the line for: a poll interval, a kill moment that is the test's own input, a semaphore the test itself releases, and a cancellation-only stand-in. The Reviewer's ruling in its verdict on PR #211 (#160).

**70. A hands-free sitting.** Proposed. A sitting with no steps for Jake, opened only after he types "hands free" in the Live checks session (`scripts/live-lane.sh sitting start --hands-free`), so hands-off fn items run while his daily app is quit and reopened as Q8 says. It uses neither of Q7's two daily slots, since it asks nothing of his hands. Jake's yes on the M1 plan covers building #225 (its fillers line: "a hands-free sitting must quit the daily app", [plan](https://github.com/jparker2006/lexicon/issues/88#issuecomment-6120839008)), but his own words on the sitting itself are not recorded. #225's builder. Lives in AGENTS.md, Dev builds and the live app, and workflow.md, Live checks.

## Current: the product (spec part 3)

Items 25 to 60 come from the spec's first comment, part 3, "what building M0 changed". Each says what the spec said, what was built, and who decided.

### Decided by Jake

**83. An app macOS does not name as focused waits for ⌃⌘V.** Spec (History, retention, paste-last): where "same field" can't be detected, "same app and under 5 s". Found in #60's Live checks: macOS names no focused app when that app has no focused element, so pasting there would mean guessing the frontmost app, which is wrong while a non-activating panel (Spotlight, a password manager) takes the keys. Asked by the orchestrator in its session, quoting [the question on #60](https://github.com/jparker2006/lexicon/issues/60#issuecomment-6130184779): "Jake: decide what happens to a Dictation in an app that shows no text field (Finder, an app with every window closed): wait for ⌃⌘V, or paste it if it lands within 5 s." Asked as question 6 of a batch of five, with "Wait for ⌃⌘V" as the recommendation; Jake, about 2026-10-13 02:57Z: "6 yes" ([record](https://github.com/jparker2006/lexicon/issues/60#issuecomment-6137201813), [time and question](https://github.com/jparker2006/lexicon/issues/60#issuecomment-6137366517)). The decision, in the record's words: "A Dictation in an app with no focused text field (Finder, an app with every window closed, or any app macOS does not name as focused) is held for paste-last with the "Press ⌃⌘V" pill, never pasted by guessing the frontmost app. The 5 s fallback still applies wherever macOS names the focused app. The Live criterion "5 s fallback in one app that exposes no focused field" is waived." Item 74 holds the rest of the late-text reading.

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

**79. The 20-minute cap and its 19-minute warning act 50 ms after their marks.**
> Jake: decide whether the 20-minute cap may act 50 ms after the 20-minute mark. I recommend yes. [...] Yes (recommended): the cap stops the recording at exactly 20:00 (the audio ends there), but acts 50 ms later. So an Esc or a tap of fn pressed just before 20:00 always counts, whichever the fn tap sees first. Cost: if fn-up was lost, Quit can wait 20 minutes plus 50 ms instead of exactly 20 minutes. [...] No: the cap acts at exactly 20:00 and Quit never waits past it. Cost: an Esc pressed in the last few milliseconds before 20:00 can arrive just after the cap and be ignored, so that Dictation is typed instead of held. ([#58](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6126616497))

Jake, asked by the orchestrator in its session, 2026-10-12 (recorded 14:54:52Z): "cap yes" ([record](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6126756110)). Decided: the cap's stop is stamped at the cap and acts 50 ms later, as the double-tap window's drop does; #58's "Quit waits no longer than the cap" becomes "no longer than the cap plus 50 ms". `FnGesture.lateKeyGrace`.

> Jake: decide whether the 19-minute warning sound may also play 50 ms after 19:00, the same as your "cap yes" for the cap. I recommend yes. [...] Yes (recommended): a key pressed just before 19:00 always counts the same way, whichever the fn tap sees first. ([#58](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6127087016))

Jake, asked by the orchestrator in its session, 2026-10-12 (recorded 15:15:50Z): "yes" ([record](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6127137470)). Decided: the 19-minute warning acts 50 ms after its mark too.

**80. Esc is taken from the confirmed Dictation, not from fn-down.**
> Jake: decide whether Esc reaches your app during the first third of a second of holding fn (PR #262, DECISIONS item 75, Proposed). #58 says Lexicon takes Esc "at recording start", the moment fn goes down. The build takes it only once the hold is confirmed (0.3 s) or on the second tap of a double tap. [...] Keep the build (recommended): Esc pressed in that first 0.3 s, or between the two taps, does its normal job in the front app (closes a dialog, cancels in the terminal). The half-started take is dropped: nothing typed, nothing in History. A stray fn tap or the Globe key never eats your Esc. ([#58](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6128270245))

Jake, asked by the orchestrator in its session, 2026-10-12 (recorded 16:31:39Z): "yes" ([record](https://github.com/jparker2006/lexicon/issues/58#issuecomment-6128393563)). The question's and the record's "item 75" is this entry, renumbered because #144 took 75 and #266 took 78. Decided: the Esc hotkey is registered when the recognizer confirms the hold (0.30 s) or the second tap, and removed when the Dictation ends; an Esc in the first 0.3 s or between the taps reaches the front app and the half-started take is dropped (item 43). Registered with and without fn, since a hold keeps fn down. Replaces #58's "registered at recording start".

**59. M1 takes Esc and ⌃⌘V with a registered hotkey first.**
> Q1: How M1 blocks Esc and ⌃⌘V (#58, #62). Today Lexicon only listens to keys, so Esc while recording and ⌃⌘V also reach the app in front. Blocking keys the old way added 26 to 74 ms of delay to every key you typed. Options: (a) a registered hotkey for Esc, held only while recording. [...] (b) a key-blocking tap that is on only during a Dictation, with its delay per key measured. Either way, typing delay while Lexicon is idle has to stay at 2 to 12 ms. ➡️ Rec: (a). #58 tests it first and falls back to (b) only if it fails.

Jake: as item 57. #58 spikes the registered hotkey and falls back to (b) only if it fails; #62 uses the same approach. [ADR 0004](adr/0004-listen-only-fn-tap.md).

**78. In Private mode, a Re-speak with no close match changes nothing.** Spec: Private mode "picks by sound alone". Built (#82): by sound alone, the span that sounds most alike is replaced only when its distance from what Jake said (0 the same, 1 nothing alike; mostly sound, partly spelling) is 0.5 or less; otherwise nothing changes and the pill says "no match", as when Jev says none.
> Jake: decide what a Re-speak does in Private mode when nothing in your last Dictation sounds like the word you said again. I recommend it changes nothing and the pill says "no match", the same as when Jev says none. [...] Reply "yes" to take that.

Jake, 2026-10-12 15:52:33Z: "yes". Recorded on [#82](https://github.com/jparker2006/lexicon/issues/82#issuecomment-6127755452). Asked as item 76; numbered 78 because open PRs took 76 and 77 first. The 0.5 limit and Jev's 0.75 are starting values, tuned on the Test set once Jake says yes to the paid Jev calls. Proposed, from #82's builder and not asked: the same sound-only rule when Jev can't answer outside Private mode (offline, no key, past its 250 ms budget, an error); Jev's top answer "none", at any probability, changes nothing; choices come only when Jev's top answer is a span under 0.75, up to 3 of the spans Jev ranked, never "none"; Jev is shown the 4 spans that sound most alike (#81's limit); the finder ranks by sound and spelling only, with no weight for Lexicon Terms, since the re-spoken text has already been through Cleanup with them.

**82. The AI cleanup guard's filler rule is #75's, not #163's.** #163 widened what rules-only Cleanup keeps (number repeats, "like" before a number or a name, "uh huh"). The structural check's contract lets a filler go only "where the rules would also drop it", so the Reviewer asked that #163 also hold the guard to the new keeps. The guard has no caller until #75, and every review round on it found a new edge case. Question, on [#163](https://github.com/jparker2006/lexicon/issues/163#issuecomment-6131529924):
> Jake: decide whether the AI cleanup guard work moves from this ticket to #75, so #163 can ship the fixes to what gets typed today.
>
> What you'd see: today Lexicon types the rules-only Cleanup. PR #245 fixes it so it stops changing what you said: "twenty twenty six", "ten ten", "five five five", "go go go", "uh huh", "like, eighty minutes", "like, Postgres", "etc." all stay as spoken. Those fixes are done and green.
>
> The Reviewer also asked the AI cleanup guard (the check that will vet AI cleanup once #75 turns it on) to refuse dropping anything those rules keep. Nothing calls that guard yet. Fourteen review rounds on it have each found a new edge case in how it matches a kept "like" to its word (dashes, line breaks, "like" as a verb versus a hedge). Each fix is real, but none of it can change what you see until #75, and each round costs about an hour.
>
> - Move it (recommended): this PR keeps the guard as it is on main, and "the guard keeps every filler the rules keep" becomes an acceptance line of #75, built where the guard goes live and can be tested on real AI output. You get the typed-text fixes now.
> - Keep it here: I keep closing guard edge cases in this PR until a review round comes back clean. The typed-text fixes wait with it.
>
> I recommend moving it. Reply "yes" to take that.

Jake, in the orchestrator's session, about 2026-10-13 02:57Z (2026-10-12 19:57 PDT), answering it as question 7 of a batch: "7 yes". Time from the orchestrator's [addendum](https://github.com/jparker2006/lexicon/issues/163#issuecomment-6137903411). Decided: PR #245 keeps the guard's filler rule as it is on main and ships the typed-text fixes; "the guard refuses to drop any filler or word the rules keep" is an acceptance line of #75, built where the guard goes live. Recorded on [#163](https://github.com/jparker2006/lexicon/issues/163#issuecomment-6137202359). The number tables the rules share with the guard gain trillion, quadrillion and quintillion, and `StructuralCheck.unvalued` names the number words they give no value; that is vocabulary, not the filler rule.

**60. The lag bar's power state.** Settled by grill Q9 (c): the state Jake normally dictates in, with the other reported beside it. Jake, 2026-10-12 04:25:38Z: "recs for all" (Q6 to Q10).

**75. A mic that gives no sound fails with "No sound from the microphone".** Neither the spec nor this file had the rule; #4 left `silentInput` ("exactly-zero samples in the first ~300 ms") declared and never raised, and #144 asked for it. Built: when every raw frame of a hold (before conversion to 16 kHz) is exactly zero, or no frame arrives at all, the Dictation is not transcribed. Its row is failed (`microphone: zeros` or `microphone: noFrames`) with its audio kept, and the pill shows "No sound from the microphone". Judged over the whole hold at fn-up, not its first 300 ms, so a device that starts with zeros and then delivers audio is still transcribed, and Jake learns of a dead mic only at fn-up (the pill shows no notice while recording). Esc, or sleep, on a silent hold fails the same way instead of transcribing, and a Retry from History of an all-zero clip does nothing. A file of zeros (eval, the dev hook) fails the same way. Stray taps and chord cancels stay silent. Item 41's start limit covers only an engine that never starts; one that starts and delivers nothing is this case. A mic that stops after delivering some audio is caught by neither: its Dictation transcribes what came.
> Jake: decide what Lexicon does when your mic sends nothing but digital silence for a whole hold [...] the pill says "No sound from the microphone", nothing is typed, and the Dictation shows in History as failed with its audio kept. [...] Pressing Esc on a dead mic fails the same way [...] and Retry on it does nothing. Reply "yes" to take that.

Jake, 2026-10-12 14:22Z (asked by the orchestrator in its session): "yes". Recorded on [#144](https://github.com/jparker2006/lexicon/issues/144#issuecomment-6126205597); the question is [#144](https://github.com/jparker2006/lexicon/issues/144#issuecomment-6126174486).

**84. Lost audio is said: "Part of the audio was lost".** Neither the spec nor this file had the rule; frames the ring refused were only logged. Built (#179): when the mic drops part of a recording (frames the 2 s ring refused), the Dictation is still heard and typed from what was captured, and the pill shows "Part of the audio was lost" with the error sound, until the Dictation lands. Asked by the orchestrator on [#179](https://github.com/jparker2006/lexicon/issues/179#issuecomment-6137742157) as question 11: "Jake: decide whether Lexicon tells you when the mic drops part of a recording. Recommended: yes, show "Part of the audio was lost" after that Dictation (with the error sound; the line shows until the Dictation lands)."

Jake, 2026-10-13T04:29Z, in the orchestrator session: "11 yes". Recorded on [#179](https://github.com/jparker2006/lexicon/issues/179#issuecomment-6138248868). Proposed, from #179's builder and not asked, beyond his words, which named the mic only: the same line shows for the other audio a capture can lose, input the converter failed on (at the very end, what it still held) and the unread rest of a file input whose read broke off (eval, the dictate hook); when the same Dictation also lost its file ("Can't save audio to disk", spec #4), both sound and the disk line is the one that stays; a failed close is logged, not shown, since `CAFFile.finalize` repairs the file and nothing is lost.

### Proposed: built on an agent's default, never asked

These stand as built until Jake confirms them as a batch or names items to change, in the next grill round.

**34. The fn tap is listen-only.** Spec: one active, session-level CGEventTap. Built: a listen-only tap, started only when `CGPreflightListenEventAccess()` already reads true (it does with Accessibility alone, so there's no prompt). Measured live: keys reached the focused app 26 to 74 ms late through the active tap (five presses timed), 2 to 12 ms through listen-only. The orchestrator and Reviewer's choice, PR #123; Jake got a heads-up, not a question. Item 59's question, which Jake answered, kept idle typing delay at the listen-only figure. [ADR 0004](adr/0004-listen-only-fn-tap.md).

**35. Sounds are warm on demand.** Spec: an always-warm audio engine. Built: the output engine starts with the Dictation and stops 3 s after its last use (never with Sounds off), because a running output engine stops the Mac from idle-sleeping. Start, stop and warning sounds take 7.7 to 10 ms; a cold cue takes 28 to 35 ms against a 20 ms target. #55's builder; written as "Jake's call" in the Later list without asking him (PR #110).

**36. The local model loads at launch, and fn-up waits at most 2 s for it.** Spec: load on fn-down if not resident. Built: also at launch; a load still running 2 s into fn-up sends the Dictation to waiting (`localModelLoading`) and retries it, because the first load of each new build compiles for about 25 s. #56's builder (PR #129).

**81. The local model gets 30 s plus a quarter of the clip to answer.** Spec (Local residency): "The local model transcribes the clip on fn-up." Built (#201): once fn-down's load is done, the local side has 30 s plus a quarter of the clip's length to answer (a 20-minute clip gets 330 s); past it the Dictation waits for a working model (`localModelFailed`), with its audio kept, and a Retry stuck on "Retrying..." comes back. A hung CoreML call can't be aborted, so until Lexicon is relaunched every later Dictation waits behind it and goes waiting: after up to its own limit (at least 30 s, whatever its length) while the model stays loaded, or after item 36's 2 s once the idle unload has queued behind the hung call. Also built: when fn-down's load fails, fn-up answers with that failure at once and does not load again (that could be a 25 s compile at the cursor); the waiting loop tries the model again every 30 s (item 40). Proposed by #201's builder and its ticket's verifier, never asked: the limit holds fn-up far longer than item 36's 2 s, but only when the model has hung.

**37. The pill and start sound wait for the 0.30 s hold.** Spec: "listening" shows when the first buffer arrives. Built: recording starts at fn-down, but nothing shows or sounds until the hold is confirmed, so fn+arrow chords and stray taps stay silent. #55's builder (PR #110).

**38. Start at login: the daily copy only, once.** Built as the spec for the daily copy, plus: Lexicon Dev never registers itself, and the daily copy registers once, so a login item Jake removes stays removed until he turns it on in Lexicon's menu. A Dev build at login would answer fn beside the daily copy. #57's builder (PR #138).

**39. First-run setup.** Built: four rows (Microphone, Accessibility, Speech model, Try it); the download starts by itself once both permissions are granted, and Private mode stops it; a left click on the warning dot opens the missing step, a right click the menu. The fourth row was the spec's own assumption; the rest #57's builder (PR #138).

**40. Waiting retries.** Built: a retry tick every 30 s; a waiting Dictation is judged by the app it was made in; once Private mode denies its retry, it stays local even after Private mode goes off, because its words are fixed and failing closed is safer. #59's and #68's builders (PR #125, PR #140); the retry cases were shown to Jake as a planning assumption, and the Reviewer listed the rules as "Jake can overrule".

**41. Mic start has a time limit, with one gap.** Built: the engine gets 2 s to start (up to 60 s while the macOS mic prompt waits); after that the Dictation fails with a notice and a History row, and the next fn-down builds on a fresh queue. Gap: words spoken while the macOS mic prompt is up are never captured. Proposed: accept the gap, and have that notice say to speak again. #142's builder and the orchestrator (PR #146).

**42. Text that cleans to nothing is silence.** Built: blank text after Cleanup or a Retry is a failed "silence" row, never an empty Cmd-V; a Retry of a settled row that cleans to blank leaves the row as it was. #145's builder (PR #148).

**43. Chord cancel shipped in M0.** Spec: M1. Built: another key in the first 0.30 s cancels silently, so fn+arrow works from the first build. Decided when #53 was written.

**44. Our own fn state machine, not Hex's code.** Spec: copy Hex's state machine and tests (MIT). Built: a smaller fn-only machine with Hex's test scenarios; no Hex code copied. #53's builder (PR #123).

**74. The 5 s late-text fallback counts from fn-up (or the ⌃⌘V press), and late text keeps the "Not typed" pill.** Spec (History, retention, paste-last): where "same field" can't be detected, "same app and under 5 s", with no start named; held text shows "Dictation ready, paste-last to insert", while the spec's pill list says "Not typed. Press ⌃⌘V to paste it.". Built: the fallback applies when the app exposed no focused field when the target was captured (fn-up, just after the release), read as an app that answers it has no focused element (no value, the attribute unsupported or not implemented) once the system-wide query names it as the focused app; an app that query can't name is nowhere to type, since the frontmost app is not always the one taking keys (a non-activating panel takes them); an answer that can't be read (a timeout or any other error) is read once more if the focused app is still the same one (up to 300 ms more, only then), and one that still can't be read is not "can't be detected" but nowhere to type at fn-up and a hold at the paste, so an app that never answers only ever holds text; a paste checked 5 s or more after that is held for paste-last (reason `tooLate`), so a slow Dictation in such an app is not typed. The 5 s keeps counting while the Mac sleeps, so a lid closed mid-Dictation holds the text. ⌃⌘V captures its own target at the key press, so it is held as too late only if its paste waits 5 s behind earlier ones (about 2 s per missed paste ahead of it). A held Dictation shows the pill list's line when it is the newest one and Jake isn't recording. #60's builder ([sketch](https://github.com/jparker2006/lexicon/issues/60#issuecomment-6124271421)). Jake decided the app-with-no-field part: item 83.

### Moved to a later milestone

- **45.** Long Dictations: a 20-minute Dictation waited 25 to 41 s at fn-up (#47). #117 decodes Parakeet's own 15 s windows while Jake talks, instead of switching to its streaming mode (the ticket allowed either): the streaming encoder is a second download of about 565 MB and scores worse in FluidAudio's benchmark, and the windows are the one-shot path's, so the words are too. It applies to every Dictation longer than one window (14.96 s), push-to-talk as well as hands-free; one that fits in one window is decoded at fn-up, as before. On a synthetic 20-minute WAV fed at real time (release builds, one run a side, provisional) fn-up to text was 388 ms against main's 8,964 ms, the pair Jake kept when he stopped the timed runs; after the per-window decode moved into Lexicon, the PR #242 review asked for numbers at that code, and one more run in one build slot gave 197 ms, with main's text. The p95 verdict is a Live checks run on a quiet Mac. Proposed: Jake was not asked about windows over streaming mode, or about push-to-talk.
- **46.** Quit and the clipboard restore: quitting right after a paste, or during item 26's 2 s hold, could leave Dictation text on the clipboard. Proposed, built in #132 (the ticket left the cap to the builder): Quit waits for the restore of the paste up when it starts, at most 2 s (the hold's length), then restores at once unless Jake copied since. The cap is per paste: a Dictation fn starts meanwhile is waited for in turn, its paste with its own 2 s from when quit takes it up, so each extra Dictation adds at most its own landing and 2 s.
- **47.** The "same app and under 5 s" late-text fallback for apps whose field can't be detected: built in #60, as item 74 says.
- **48.** The audio retention sweep runs at launch only, not on a rolling schedule. No ticket yet.

### Facts the spec got wrong

- **49.** Gold review: 250 clips to review (194 everyday, 56 held back), 117 minutes of audio, against the spec's estimated 100 to 150 clips. About 2 to 2.5 hours at normal speed; the review runs in short chunks (#51).
- **50.** Test set split: 100 held back and 360 everyday (460 clips), not 341 everyday. #78 follows 360.
- **51.** Model download: about 614 MB in code, 595 MB on disk, not 609 MB. Proposed: the spec says about 600 MB, and the exact figure lives in one constant.
- **52.** Launch to fn working, 150 ms: met on warm relaunches (35 to 137 ms), missed on the first launch after an install. Proposed reading, used in architecture.md Budgets and `scripts/bench.sh`: p95 of warm relaunches, with the first launch after an install reported on its own.
- **53.** History open, 100 ms at p95: the quiet-Mac rerun gave p95 127 and 139 ms over 20 opens, a fail; #150 fixes it. Proposed reading, used the same way: p95 over every open, with the first open after launch also reported on its own.
- **54.** Lexicon's own work, fn-up to Cmd-V, 10 ms: cold first pastes measured 7.1 to 14.0 ms (#54), under load. A quiet-Mac recheck is still owed.
- **55.** Memory while dictating, about 160 MB: peak 66 to 68 MB on a 6 s clip, 258 MB on a 20-minute clip (#47). With #117 the 20-minute peak was 108 MB, and 112 MB after the per-window decode moved into Lexicon (synthetic WAV, release, one run each), against 250 MB for main on the same WAV: a long Dictation no longer converts the whole clip at fn-up. Proposed: 160 MB holds for every Dictation.

- **68.** The spec lists "`CloudAccess` is the only door to the network" among the compiler-enforced invariants. Only the key is: every cloud key comes through a `CloudAccess`, but the sockets and HTTP calls are plain `URLSession` that would take any request. architecture.md says so; keeping the network behind `CloudAccess` is a review rule (review.md).
- **76.** Zero retention, which the spec requires before any eval sends Test set audio to a provider (spec "Privacy for eval"), is not on by default for the bake-off's speech providers. Meta's is for organization accounts only ([#111](https://github.com/jparker2006/lexicon/issues/111)); Cartesia Ink and ElevenLabs offer it on Enterprise plans only. [#166](https://github.com/jparker2006/lexicon/issues/166) enforces the spec's rule in code; whichever of these [#77](https://github.com/jparker2006/lexicon/issues/77) adds as a `CloudModel` states its status there.

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
- **Long Dictations switch to Parakeet's streaming mode** (the spec, Local residency), by item 45's windows decoded while Jake talks (Proposed).
- **60 ms to first audio, cold or prepared** (the spec), by item 30: the budget is the prepared path.
- **Tickets Jake can feel stay open until he closes them** (workflow.md, M0), by Q11.
- **Jake promotes Later items himself** (review.md, M0), by Q13.
- **Two build slots** (item 66's first half), by item 77: first come, first served, with a third slot while the Mac has room.
- **Every live item gates the merge** (workflow.md, M0), by Q6.
- **Only Jake quits his daily copy** (workflow.md, M0), by Q8.
- **A builder grills its own issue and waits for Jake's OK** (workflow.md, M0), by Q5.
- **gstack's one-time browser download** (the third yes at 04:31:43Z): dropped. Jake, 05:05:43Z, when the orchestrator said agents only reached for gstack because his global CLAUDE.md told them to: "yeah remove the line, rec for both"; then, on cutting the whole gstack section, 05:07:43Z: "yeah cut it". The #88 checklist records the download as dropped because he doesn't use gstack. `.gstack/` stays in `.gitignore`.
