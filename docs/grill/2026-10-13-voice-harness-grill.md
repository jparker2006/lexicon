# Voice harness grill record (2026-10-13)

The grill on [#136](https://github.com/jparker2006/lexicon/issues/136), "Idea: Lexicon as a domain-specific harness for voice (after v0)". Jake asked for it in the orchestrator's session on 2026-10-13 and answered in a grill session from 16:22Z to 18:00Z, one question at a time, each with a recommendation. **Nothing here is built or planned.** The answers shape a parked idea; none changes what Lexicon does or what v0 plans, so no entry in [DECISIONS.md](../DECISIONS.md) changes. If the idea is planned, each answer that still holds goes into DECISIONS.md with the words and times below, and [What it would reopen](#what-it-would-reopen) names the entries it touches. When and whether any of it is built goes back to the orchestrator.

## The idea in one paragraph

Lexicon stays a fast, private voice-to-text app everywhere, and becomes very strong at the thing Jake uses it for most: dictating prompts to coding agents. A smart model runs **always on, in the background**, reading only his agent sessions (Claude Code and Codex) and the Dictations he made into them, and keeps a running picture of what is going on. **While he talks**, Jev makes many quick decisions from that picture, so names, files and issues come out right. **After he lets go**, a small toast offers what Lexicon thinks the prompt is missing, only when Jev is confident. On its own, Lexicon only fixes what it heard; anything that changes the meaning is an offer he clicks or ignores.

**The first principle:** talking to a coding agent means getting what is in Jake's head into the agent's head so the right thing gets built, in as few rounds as possible. Lexicon shrinks the gap between what he meant and what the agent builds, and for now it does that before he presses Enter.

Jake's own summary (Q21): "That means we're super strong when it comes to prompting agents, but also keep privacy. So we are still a reliable voice to text app for other things."

## The shape

| Step from head to build | What gets lost | Lexicon's part | Status |
|---|---|---|---|
| 1. Head to speech | Half-formed thoughts | The "tighter version" toast; ideas 1a and 1b below | Ideas |
| 2. Speech to text | Wrong words ("beats whisper", "Jeff") | The harness: the brain, its memory, the session brief | Core |
| 3. Text to agent | Missing context, ambiguity | Jev and the toast | Core |
| 4. Agent to build | It built the wrong thing | Not Lexicon's place for now (Q26) | Parked |

Three speeds, as proposed in the session (Jake did not object; not asked as its own question):

- **The brain** (seconds to minutes, background): a strong model on Jake's Codex subscription that wakes on real changes (an agent reply, a window switch, a merge) and writes a short brief per session: names in play, what the agent last asked, Jake's usual phrasing.
- **Jev** (about 150 ms, every Dictation): many typed questions answered in one request, reading the brief, before and after the text lands.
- **Cleanup** (one call with a deadline, as v0 builds it): reads the brief, so it spells things the way the session does.

## Questions and answers

Times are UTC on 2026-10-13. Each answer is Jake's, verbatim.

**Q1. What is the idea?** Options: voice to agents, a kit for any domain, voice that acts, the factory itself. Rec: voice to agents.
> "im not sure what this idea is. I just know the idea of a "domain specific harness" as well as like a peronal ai bot. im thinking about how that works when you make voice to text the domain. what tools do we give the agent? whats skills? how do we put a harness behind voice to text" (16:22:56)

**Q2. When does the agent run?** Options: between Dictations, on every Dictation, only when called, a background learner plus a callable agent. Rec: the last, built background-first.
> "yeah i guess thats sort of the idea? look at how we use hermes in Glox brain lab... that is sort of it... and our idea for domain specific harness. research that a bit first. this isnt related to glox at all btw theres j good ideas in that repo" (16:27:04)
>
> "not even neccesarily only when the pipeline runs. even in the background since it can analyze your history" (16:29:16)

Outcome: the agent runs any time, in the background as well as around a Dictation. Q21 later narrowed what it reads to agent sessions and the Dictations into them.

**Q3. What may the background agent change without asking?** Options: nothing, anything the Test set says helps, small learning alone and bigger changes ask. Rec: the last: a Term or Rule on its own only when two or more of Jake's Fixes back it and the Test set scores no worse; anything that changes how he is written is a proposal; a weekly list with undo.
> "C is fine I guess. The thing im thinking about is more proactive than were thinking. I also have a feeling the technical implementation to get this working is to abuse Jev calls" (16:42:03)

**Q4. What does "proactive" look like?** Options: it reaches out, it gets ready before you speak, it fixes after typing, it acts on what you said. Rec: get ready and fix after.
> "What if we think about the specific use case of voice to text in the context of prompting a coding agent. That is mostly what I use voice to text for... Maybe B and def C (thats basically what were about to build). Like im thinking in an iron man way. I feel like no one has really put a true harness implementation behind a voice to text app before" (16:45:29)

Outcome: the domain narrows to prompting coding agents; "fixes after typing" yes, "gets ready before you speak" maybe.

**Q5. What should Lexicon know about the agent?** Options: repo names as today, the screen's text, the agent's own session. Rec: the session.
> "Yeah it should definitely have a tool to know the session that its in. that woukd be cool." (16:47:35)

**Q6. How far may Lexicon change what you said?** Options: spell it the session's way, also attach what you pointed at, turn it into a better prompt. Rec: spell only.
> "hmm this is the interesting part. we know were dictating into one prompt box for this specific use case were thinking of. maybe C? idk i feel like we should harden the idea before we decide this part. dont make a decision on this" (16:49:32)

Outcome: Proposed. Jake said not to decide this. After Q11 and Q15 the session stated a reading, which Jake did not answer either way: on its own Lexicon only fixes what it heard; meaning changes come as a toast.

**Q7. What counts as doing well?** Options: words right, prompts sent untouched, the agent gets it right the first time, thought to agent working. Rec: the third as the goal, the second as the everyday score, the first as the floor.
> "Yeah I guess C"
>
> "I feel like theres a lot of things that can be improved on in current voice to text. Like it should be more proactive. It is the tool i use the most yet it is so dumb! All it does is go voice to text! It should be more like a personal agent with all that data" (16:52:38)

Outcome: the goal is the agent getting it right the first time. "Prompts sent untouched" and "words right as the floor" were the recommendation, not his answer: Proposed.

**Q8. The first thing the agent does unasked?** Options: remember for you, stop you repeating yourself, track open loops, guess your next reply. Rec: stop you repeating yourself.
> "hmm i guess B, but honestly none of these are what I had in mind" (16:54:10)

**Q9. Design the jobs, or give it tools and let it find them?** Rec: a true harness: a toolbox plus starter skills, judged on Q7's goal.
> "Yeah B makes sense. Are we thinking we literally give our model (cleanup model?) a harness? look back in my voice to text history. wheres a place a harness thats more proactive and less "dumb" than current voice to text wouldve improved my prompt" (16:57:05)

His History and Wispr export stay closed (AGENTS.md, Private data). The session read his prompts in the Lexicon repo's Claude Code sessions instead and found four patterns: words the session knew, heard wrong ("Let's do the beats whisper Grill", "I don't think Supabase can do that yet" meaning Wispr, "Wispr Flow with Jav", "10 5 5 Haiku subagents"); Jake relaying messages between sessions by hand; status questions; answers to numbered question rounds. The answer to his first question was the three speeds above.

**Q10. Which pattern is the idea?** Options: hear it right, Lexicon as the bus between sessions, Lexicon answers status itself, all three. Rec: all three.
> "I mean A is the most important, right? That's the base of a voice to text app I'm not seeing B or C. I'm seeing more like I'm dictating to the voice to text app and somehow my voice to text app lexicon knows what I'm saying and you know there are certain decisions to make within what I'm saying and it uses Jev to spam make decisions within my voice to text. I also see like say I dictate for a minute and then after I let the dictation through, maybe I see little toast that says, Oh, do you want to add this, this, this to your prompt? Or did you mean to say this, this, this? Like just a more proactive voice-to-text model. And I think Jev's quick decision making plus like a true harness mindset can get us there I don't know I just have this idea in my head and I feel like me and you aren't on the same page" (17:05:46)

Outcome: hearing right is the base, plus the toast. The bus and status answers are out.

**Q11. Is the scene the picture?** The scene: while he talks, Jev settles which words he meant from the session; after he lets go, a toast offers additions and "did you mean".
> "Yeah, I feel like that's the picture. I think I don't know. I think we're getting closer, but I don't think we're quite there. [...] what I'm thinking is like more smartness than this though [...] the thing I can't get out of my mind is watching Iron Man talk to Jarvis and it just works so perfectly because his voice to text is so smart and current voice text is so dumb. I'm just thinking how can I build a better voice text?" (17:08:58)

**Q12. Which JARVIS trait?** Options: talk messy and get what you meant, it talks back, it knows what "that" is, it's just there. Rec: the first and third.
> "honestly not sure at all. i think youre thinking too much in the voice to text sense im thinking about the app and harness outside of the voice to text maybe. like background LLM calls? with smarter models? and thats helps somehow? idk" (17:11:17)

**Q13. Does the always-on brain click?** A strong model keeps a running picture in the background; each Dictation looks things up in it; the toast comes from a second look after he lets go.
> "Yeah, that that's the direction I think. I think we should keep grilling in that direction I used to do a bunch of research on general user models or gum and it was basically this thing that would like look at your screen in the background and be proactive to agents. you should look into it. I'm not thinking exactly that, but for some reason I'm thinking like along the lines of that type of research." (17:14:36)

**Q14. What does the brain keep in its picture?** (GUM-style beliefs, fixed fields, or two layers.) Dropped: it asked about internals, not what Jake sees.
> "Honestly, I'm not sure. I kind of forgot what the gum research was. I don't like this grilling question. I feel like we shouldn't have talked about gum I just liked thinking about it'cause it's the always on thing [...] Like I just want the voice text to be smarter." (17:23:40)

Kept from GUM: always on.

**Q15. What should the toast offer?** Options: "Did you mean...?", "Add this?" (issue, file, PR), "You usually say...", "Tighter version?". Rec: add context and tighter version.
> "I mean low-key all of the above right" (17:27:09)

**Q16. How often should the toast show?** Rec: only when it's sure it matters, at most 3 items, learning from what he takes and ignores.
> "I mean yeah, this is definitely a place where Jeff comes into play. Jeff either makes one decision on whether it toasts or if we have a few different toast jobs, meaning add context, tighten up, whatever it may be, and Jeff makes a decision on all of them. And you know, Jeff has to be confident that a toast should be proposed" (17:29:39)

"Jeff" is Jev, misheard four times in a session that had said Jev all day: a live case of step 2. The session's choice, stated to Jake: one Jev question per toast kind, all in one request (DECISIONS part 2, item 23), so it costs the same as one gate.

**Q17. How do you take a suggestion?** Options: number keys, by voice, click, do nothing and it fades. Rec: voice plus fade.
> "C or D" (17:34:06)

Outcome: click it, or ignore it and it fades.

**Q18. Offline or in Private mode?** Rec: Lexicon keeps the brain's last picture on the Mac and uses it; new thinking waits for the network; a Dictation is never worse than v0.
> "Yeah rec is fine" (17:35:21)

**Q19. What may it cost per month?** Rec: under Wispr's price, after checking whether a subscription can run it.
> "Lets check if I can put it on my claude or codex sub first. if it is on my codex sub,,, lets burn some tokens lol" (17:36:25)

**Q20. When does it get built?** Rec: after v0, with a note on #75.
> "I think we should go back to the orchestrator and think about it. Because you know I could see some of it being woven into M for I don't know, this part might be I have to be a Wayfinder of like you know thinking further down the line to make the idea bigger and better, you know." (17:38:43)

Outcome: timing goes to the orchestrator; maybe part of M4; maybe a wayfinder pass first.

**Q21. What may the brain read?** Options: agent sessions only, all of History, all of History with only agent text leaving the Mac. Rec: agent sessions only.
> "Yeah, I guess it can only read the things you can prompt for agents. That means we're super strong when it comes to prompting agents, but also keep privacy. So we are still a reliable voice to text app for other things." (17:40:07)

Outcome: the brain reads only his Claude Code and Codex sessions and the Dictations into them. The Secret guard keeps keys out of everything it sends; it does not keep session or Dictation text private.

**Q22. Which subscription runs the brain?** Options: Codex for everything, each session to its own provider, Codex with Claude sessions summarized on the Mac first. Rec: Codex for everything, after a one-hour test of startup and usage.
> "lets just do codex for everything. since these are longer, smarter background calls lets use Sol 6.1" (17:47:18)

The question had said: "A Codex brain reading your Claude Code sessions would send Claude session text to OpenAI, which is new." Outcome: Codex for everything, on Jake's ChatGPT login, so Claude session text goes to OpenAI. The model check found only `gpt-6-luna` named as the small model on a ChatGPT login; Sol 6.1 is Jake's pick, to be checked against Codex's model list before it is built.

**Q23. Is the grill done?** Jake reopened it:
> "Bro, I don't know if the gorilla's done. I feel like there's still something we're missing. Like something I hate about Wispr Flow is their insights page is so shit. You would think they have all that data, their insights page shouldn't be that bad. [...] People are building domain-specific harnesses nowadays, and my domain is voiced text, right? But let's break it down to first principles. [...] First principles is I say what I want to be built, right? [...] How do we provide value to that? [...] Help me break it down to first principles" (17:51:03)

**Q24. Is the first principle "Lexicon sees both sides of the conversation and shrinks the gap between what you meant and what got built"?** Rec: yes.
> "Yeah, I think that first principles makes a lot of sense. I don't think we should focus on the insights page. I wasn't necessarily speaking directly on the insights page, I was just more speaking on we have all this data and we need to make the experience better for the user. But the voice to text just seems so dumb and non-proactive it doesn't do that, right? Let's think each first principle step. How does our voice to text agent innovate and do things that weren't possible before and don't exist yet to help the user?" (17:53:28)

**Q25. Which per-step ideas light you up?** Rec: 4b, 3b and 1a (listed under [Ideas](#ideas-recorded-not-chosen)).
> "I have no idea Yeah, you know two seems pretty you know not, solved, but it seems like the thing we're trying to solve with, some of these tools and skills and hard to harness with the memory. It seems sort of like we're trying to solve speech to text with that, right? Text to agent feels like the Jev toast stuff, right Very interesting. I think 4B is really interesting. I don't understand how it works and I don't know if that's our place. Like once the prompt is sent, is that our place to interact with the session or anything? I don't know I don't know." (17:57:08)

Outcome: step 2 is the harness and its memory; step 3 is Jev and the toast.

**Q26. Once Enter is pressed, what is Lexicon's place?** Options: none, watch and tell, watch and offer a fix, step in itself. Rec: watch and tell.
> "I don't know for some reason I'm thinking A, at least for now. At least for now I'm thinking it we shouldn't think that far ahead yet. We should get it working for other stuff." (17:59:42)

Outcome: Lexicon's job ends at Enter, for now.

**Q27. Done?** Rec: done.
> "Yeah, I think that looks good" (18:00:29)

## Ideas recorded, not chosen

- **1a. Think out loud, get it sorted:** a long ramble becomes the agent's prompt with decisions and open questions kept apart, so "I don't know" stays information.
- **1b. It asks back mid-thought:** a pause brings a quiet "Which repo?", answered by voice.
- **2b. Answer-aware hearing:** when the agent just asked "Q3: A, B or C?", Lexicon expects an answer of that shape. Part of the session brief.
- **3b. Carry what other sessions know:** "You told the orchestrator M4 is paused; this builder doesn't know. Add it?"
- **4a. Learn from "no, I meant":** a correction marks which kind of prompt was unclear, for a warning at step 3 next time.
- **4b. Check the agent understood:** read the agent's first reply and toast when it looks misheard. Parked by Q26.
- From Q8 and Q10: spotting instructions Jake repeats to agents and proposing an AGENTS.md or CLAUDE.md line; Lexicon as the bus between sessions; status answered from the sessions.

## Research behind it

**Glox's Hermes and its domain-harness idea** (read in `~/code/glox-brain-lab`; mechanisms only). Hermes is Nous Research's open agent (MIT). Glox wraps it with its own tools split into read, direct and proposal; skills that are versioned when edited; saved instruction documents; a memory store where forget hides rather than deletes; scheduled briefs; and a background review that stages changes Jake approves, with code, not the model, setting the evidence bar for a learned change. Glox's template for a domain harness: user, input, memory, tools, output, and what needs a person's yes. Lessons that carry: Glox changed what Hermes may do without asking four times in three days, and an add-only memory returned both an old rule and its correction.

**Outside sources.**
- "Harness" means the software around a model that supplies tools, memory, context and guardrails ([LangChain, 2026-06-03](https://www.langchain.com/blog/how-to-build-a-custom-agent-harness); [Anthropic, 2025-11-26](https://anthropic.com/engineering/effective-harnesses-for-long-running-agents)). "Domain-specific harness" has no settled meaning.
- No dictation app found runs an agent behind dictation. Screen-aware dictation exists, all vendor claims: Superwhisper Super Mode, Aqua, Monologue DeepContext, Wispr reading text near the cursor. Nothing found reads the agent session itself or runs typed decisions inside dictation.
- Context helps rare words: entity lists cut entity errors by roughly 8% to 46% across papers ([2506.06252](https://arxiv.org/html/2506.06252), [2309.00723](https://arxiv.org/html/2309.00723v2), [2601.15397](https://arxiv.org/html/2601.15397v1)). The usual failure is a model inventing or over-correcting words ([2510.13281](https://arxiv.org/pdf/2510.13281)); detecting first, then verifying, helps ([2505.24347](https://arxiv.org/html/2505.24347v3)). A picker that can answer "none" avoids most of it (an inference).
- Suggestions: about 30% of Copilot's inline suggestions are accepted ([ITPro](https://itpro.com/technology/artificial-intelligence/github-30-of-copilot-coding-suggestions-are-accepted)); a proactive coding assistant got 53% engagement and 12% disruption, best at task boundaries ([2502.18658](https://arxiv.org/pdf/2502.18658)).
- Jev: no independent check of its calibration; its "confidence" is not the chance it is right ([noze.it](https://www.noze.it/en/insights/jev-system-one-typed-decisions/)). Any toast bar is tuned on the Test set, not trusted.
- **Stanford's General User Models** ([arXiv 2505.10831](https://arxiv.org/html/2505.10831v1), [repo](https://github.com/GeneralUserModels/gum)): plain-language beliefs about a user with a confidence, a decay rate and evidence, written by a large model from screenshots; its assistant speaks only when interrupting is worth more than silence, at most once a minute. Only 25% of its suggestions were rated good in a five-person study. Kept: always on. Clashes: screenshots (grill D5) and data-center-sized models.

**Subscriptions.**
- Codex: `codex exec` reuses the ChatGPT login ([non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)); Pro has no 5-hour limit ([pricing](https://learn.chatgpt.com/docs/pricing)). Unverified: whether `codex exec` draws from the same pool as interactive coding, its startup time, and whether OpenAI's terms cover a person's own script on their own login.
- Claude: `claude -p` on a `claude setup-token` login is documented "for CI pipelines and scripts" ([authentication](https://code.claude.com/docs/en/authentication)), but the usage policy bars "services that route requests through consumer subscriptions" ([AUP](https://www.anthropic.com/legal/aup)). Not chosen.
- Shipping to anyone else would need per-user API keys or each company's partner program.

## What it would reopen

Building any of this reopens these, each through Jake in DECISIONS.md first:

- GLOSSARY, Jev: "no call happens during plain dictation"; and DECISIONS part 2, item 6, "Jev for close calls is dropped". The idea puts Jev on every Dictation.
- DECISIONS part 2, item 17: code context is names only, "no identifiers or file names". The session brief carries both.
- GLOSSARY, Hook: Lexicon has no product hooks "unless the after-M1 grill brings them back". The session tool may need one.
- The structural check and Cleanup's "never changes what you asked for": the "tighter version" and "add this" toasts change meaning, but only when Jake clicks them.
- DECISIONS part 2, item 10: when a Fix becomes a Rule is the after-M1 grill. Q3's rule (two or more Fixes, the Test set no worse) is an answer to that question.
- architecture.md, Privacy: "Jev gets only the few words around a Re-speak or Hand fix target plus candidates." The session brief sends Jev far more, on every Dictation.
- What leaves the Mac: the Dictations into agent apps are History rows, and Q21 and Q22 send their text, with the session text, to OpenAI. Today every cloud call (speech, Cleanup, Jev, model downloads) takes a `CloudAccess`, and none happens in Private mode. The brain's calls would need the same door and the same Private mode cut.
- Grill D5, no screenshots, stays: the brain reads session files and text, never pixels.

## Open, for the orchestrator

- When and where: maybe part of M4, maybe a wayfinder pass first to make the idea bigger.
- The cheapest test of the core: does the session brief raise the Terms score on the Test set?
- The toast needs a 10-item trial with Jake (workflow.md, Human time) before anyone trusts it.
- Sol 6.1 on a ChatGPT login, `codex exec` startup time and its effect on usage: one-hour test.
- Words used here and not added to GLOSSARY.md, since nothing is built: **brain** (the background model and its running picture), **session brief** (what it writes per session for the fast path), **toast** (the after-Dictation suggestions).
