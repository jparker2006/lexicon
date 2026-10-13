import Foundation
import os
import LexiconDomain
import AppText
import Cleanup
import WordStore

// A Re-speak with words selected (#83): the selection is replaced by what Jake
// said, no Jev. Only a live target reaches here, so a recovered or retried
// Re-speak never edits any app. Without a selection the span is found by sound
// and Jev (#82, #85).

extension Conductor {
    /// What the replace did, for the bookkeeping after the insert turn.
    enum RespeakStep: Sendable {
        /// Nothing was selected: the span is found by sound (#85).
        case noSelection
        case replaced(field: FieldText, selection: FieldSelection, with: String, receipt: InsertionReceipt)
        case notLanded(FixProblem)
    }

    /// What fitting the spoken words needs that takes time: the Lexicon's Terms
    /// and a scan of the system word list. Read before the insert turn, so it
    /// overlaps an earlier Dictation's paste. A Dictation spoken after the
    /// Re-speak still waits for the Re-speak as a whole: its place in line keeps
    /// that Dictation from pasting over Jake's selection.
    struct RespeakWords: Sendable {
        let terms: Set<String>
        /// Each word `RespeakText` may ask about, and whether it is plain English.
        let english: [String: Bool]
    }

    func respeakWords(_ spoken: String) async -> RespeakWords {
        // Every Term, not the fn-down selection: a Term's spelling is right wherever it is used.
        let terms = Set(await lexicon.terms.map(\.text))
        let asked = RespeakText.plainnessQuestions(spoken)
        let english = await Task.detached {  // off the Conductor
            Dictionary(uniqueKeysWithValues: asked.map { ($0, PlainEnglish.contains($0)) })
        }.value
        return RespeakWords(terms: terms, english: english)
    }

    /// Under the insert turn, so it waits for earlier Dictations' pastes. Reads
    /// no SQLite and no word list: the next Dictation may be waiting for this turn.
    /// Worst case, an app that answers slowly at every step: the read's 100 ms of
    /// retries, 250 ms to show the selection, the paste lane's wait for an earlier
    /// unread paste (as an insert has), 100 ms for the caret and 250 ms to show the
    /// fix, plus Accessibility's own timeouts; a field that answers takes milliseconds.
    func replaceSelection(_ spoken: String, at target: Destination.Target, words: RespeakWords) async -> RespeakStep {
        guard let field = await destination.read(at: target) else { return .notLanded(.noField) }
        guard let selection = field.selection else { return .noSelection }
        // Every word it asks about was looked up before the turn.
        let replacement = RespeakText.replacement(spoken, replacing: selection.text, terms: words.terms,
                                                  isEnglish: { words.english[$0] ?? false })
        guard replacement.contains(where: { !$0.isWhitespace }) else { return .notLanded(.nothingHeard) }
        return switch await destination.replace(selection.span, expected: selection.text, with: replacement, at: target) {
        case .replaced(let receipt): .replaced(field: field, selection: selection, with: replacement, receipt: receipt)
        case .unverified: .notLanded(.unverified)
        case .refused(let refusal): .notLanded(FixProblem(refusal))
        }
    }

    /// After the turn: a fix inside the fixed Dictation's text becomes a Fix on
    /// it, at its position; anything that didn't land is said, never silent.
    func settleRespeak(_ step: RespeakStep, _ spoken: String, fixing: DictationID, _ run: DictationRun) async {
        let landedIn = run.releasedAt.map { "\(HostTime.now().duration(since: $0).milliseconds) ms" } ?? "?"
        switch step {
        case .noSelection:
            // Until #85 finds the words by sound, nothing selected means nothing to fix.
            guard let fixes else { return emit(.notice(.fixNotLanded(.noSelection))) }
            _ = await fixes.respeak(spoken, fixing: fixing, access: run.access)
            return
        case .notLanded(let problem):
            log.notice("Re-speak \(run.id, privacy: .public) not landed (\(String(describing: problem), privacy: .public)) after \(landedIn, privacy: .public)")
            emit(.notice(.fixNotLanded(problem)))
        case .replaced(let field, let selection, let replacement, _):
            log.notice("Re-speak \(run.id, privacy: .public) replaced the selection, release to landed \(landedIn, privacy: .public)")
            let receipt: InsertionReceipt?, final: String?
            do {
                (receipt, final) = (try await history.receipt(for: fixing), try await history.finalText(of: fixing))
            } catch {
                // Not "never inserted": the fix is in the field, and only History failed.
                log.error("Re-speak \(run.id, privacy: .public): History unreadable, the Fix is not saved")
                return emit(.notice(.fixNotLanded(.historyUnreadable)))
            }
            // Jake can select any words; only those inside the fixed Dictation's text,
            // still found unchanged in the field, are a Fix on it.
            guard let receipt, let final, let place = DictationPlace.locate(final, receipt: receipt, in: field) else {
                return log.notice("Re-speak \(run.id, privacy: .public): no Fix row, the fixed Dictation's text isn't found unchanged in the field")
            }
            guard selection.span.location >= place.location,
                  selection.span.location + selection.span.length <= place.location + place.length else {
                return log.notice("Re-speak \(run.id, privacy: .public): no Fix row, the selection is outside the fixed Dictation's text")
            }
            history.record(.fixRecorded(Fix(dictation: fixing, kind: .respeak, source: .respeak,
                                            before: selection.text, after: replacement,
                                            location: selection.span.location - place.location,
                                            verdict: .proposed, at: Date())))
        }
    }
}

extension NotInsertedReason {
    /// The row's reason when a Re-speak's words didn't land.
    init(_ problem: FixProblem) {
        self = switch problem {
        case .movedOn: .focusMoved
        case .noField: .noField
        case .clipboardDenied: .clipboardDenied
        case .textChanged, .cannotSelect, .terminal, .pasteFailed, .unverified, .historyUnreadable, .nothingHeard,
             .noSelection, .tooLate:
            .pasteFailed
        }
    }
}

extension FixProblem {
    init(_ refusal: ReplaceRefusal) {
        self = switch refusal {
        case .focusMoved, .typedSince, .tooLate: .movedOn
        case .textChanged: .textChanged
        case .cannotSelect: .cannotSelect
        case .terminal: .terminal
        case .noField: .noField
        case .clipboardDenied: .clipboardDenied
        case .pasteFailed: .pasteFailed
        }
    }
}
