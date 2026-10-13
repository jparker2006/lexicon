public import Foundation
public import LexiconDomain

/// The cleanup stage: model text in, the text Lexicon types out (#20).
///
/// Order, fixed here and nowhere else:
///   1. Rules applied in code (`RuleSet.apply`): the "ruled" text.
///   2. LLM cleanup of the ruled text, with this Dictation's Lexicon terms in its
///      context (OpenRouter, from M3). No on-device model: Private mode and
///      offline are rules only.
///   3. `StructuralCheck` of the LLM's text against the step-1 text.
///   4. Accept it; otherwise type the rules-only cleanup (`TextPass.run`: Rules,
///      then fillers and repeats), which runs alongside as the fallback.
///
/// Finished sentences are cleaned while Jake is still talking, from the
/// provider's finalized segments, so after fn-up only the tail waits on the LLM.
/// The final call may revise the sentence before the last. Text is never swapped
/// after it is typed: `finish` returns once, and that is what gets inserted.
///
/// Until AI cleanup lands (#75) every plan is `.off` and the stage returns the
/// rules-only text.
///
/// Hides: sentence segmentation, the per-sentence cache, the OpenRouter wire
/// format and its pinned fast providers, prompts, the deadline race and the
/// fallback. Depends on LexiconDomain only.
public struct Cleanup: Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// fn-down, right after the speech attempt opens. With a cloud plan this also
    /// opens the TLS connection to OpenRouter while Jake talks.
    /// `segments` nil: no live text (retry, recovery, waiting); everything is
    /// cleaned at `finish`.
    public func begin(plan: CleanupPlan, segments: AsyncStream<SpeechSegment>? = nil) -> CleanupSession {
        CleanupSession(plan: plan, segments: segments, model: model(for: plan.engine))
    }

    /// Whole-text cleanup with the same stage: `begin(plan:)` then `finish`.
    /// One path for live, waiting, retry, recovery and eval.
    public func clean(_ modelText: String, plan: CleanupPlan, deadline: Duration) async -> Cleaned {
        await begin(plan: plan).finish(modelText: modelText, deadline: deadline)
    }

    /// The one place a plan's engine becomes a model. `.off` has none; `.cloud`
    /// cannot be built without the `CloudAccess` the plan carries.
    func model(for engine: CleanupPlan.Engine) -> (any CleanupModel)? {
        switch engine {
        case .off: nil
        case .cloud(let model, let access): OpenRouterCleanup(model: model, access: access, session: session)
        }
    }
}

/// What cleanup runs for one Dictation. Built only through `make`, from the
/// Conductor's one `Preferences` snapshot, so a toggle flipped mid-Dictation
/// never changes the Dictation in flight.
public struct CleanupPlan: Sendable {
    enum Engine: Sendable {
        /// Rules only, nothing leaves the Mac for cleanup: "AI cleanup" off,
        /// Private mode, offline, and every Dictation until #75.
        case off
        /// Hosted LLM. Impossible to build without a `CloudAccess`.
        case cloud(CloudCleanupModel, CloudAccess)
    }

    let engine: Engine
    let terms: [Term]
    let rules: RuleSet
    let app: AppContext

    /// Private mode and the toggle are ONE mechanism for the cloud: with the
    /// toggle off the plan drops `access`, and without `access` no cloud model
    /// can be built. Rules only until AI cleanup lands (#75), which turns on:
    ///   engine = preferences.aiCleanup ? access.map { .cloud(preferences.cleanupModel, $0) } ?? .off : .off
    public static func make(preferences: Preferences, access: CloudAccess?, terms: [Term], rules: RuleSet,
                            app: AppContext) -> CleanupPlan {
        CleanupPlan(engine: .off, terms: terms, rules: rules, app: app)
    }
}

/// One Dictation's cleanup in progress.
///
/// While Jake talks: consumes `segments`, keeps only finalized ones, splits them
/// into sentences (`Sentences`), applies Rules, and sends each finished sentence
/// to the model with the sentences before it as context. Results are cached by
/// their ruled text.
///
/// At `finish`: splits the real model text (which may differ from the segments,
/// e.g. when local won the race), reuses cached sentences whose ruled text
/// matches exactly, and sends the rest (the tail, plus the sentence before the
/// last so it may be revised) in ONE call. Each sentence's LLM text must pass
/// `StructuralCheck` against its ruled text; one failure rejects the whole
/// Dictation's AI text (no mixed output).
public actor CleanupSession {
    let plan: CleanupPlan
    let model: (any CleanupModel)?

    init(plan: CleanupPlan, segments: AsyncStream<SpeechSegment>?, model: (any CleanupModel)?) {
        // TODO(#75): consume `segments` and clean finished sentences while Jake talks.
        self.plan = plan
        self.model = model
    }

    /// fn-up, once the speech model's text is in. Waits at most `deadline` (from
    /// this call) for the LLM; always returns. The rules-only text is computed
    /// first (well under 1 ms), so a miss costs nothing but the wait.
    ///   - plan `.off` -> rules-only, `.off`
    ///   - model error, offline or missing key -> rules-only, `.unavailable`
    ///   - deadline passed -> rules-only, `.deadline` (late answers are dropped)
    ///   - check failed -> rules-only, `.rejected(failure)`
    ///   - otherwise -> the LLM text, `.aiAccepted(engine)`
    public func finish(modelText: String, deadline: Duration) async -> Cleaned {
        let rulesOnly = TextPass.run(modelText, rules: plan.rules)
        guard model != nil else { return Cleaned(model: modelText, cleaned: rulesOnly, .rulesOnly(.off)) }
        // TODO(#75): let ruled = plan.rules.apply(to: modelText); let parts = Sentences.split(ruled)
        // reuse cache hits; request the misses + the sentence before the last; race against `deadline`;
        // for each sentence: StructuralCheck.check(candidate, ruled: sentence, terms: plan.terms) ?? accept
        fatalError("not implemented")
    }

    /// Cancelled or discarded Dictation: drop in-flight requests and stop reading segments.
    public func cancel() {
        // TODO(#75): cancel the in-flight request and the segment reader.
    }
}

/// The cleanup stage's answer: the versions to record and type, and how it got there.
public struct Cleaned: Sendable, Hashable {
    public let versions: TextVersions
    public let outcome: CleanupOutcome

    init(model: String, cleaned: String, _ outcome: CleanupOutcome) {
        self.versions = TextVersions(model: model, cleaned: cleaned)
        self.outcome = outcome
    }
}
