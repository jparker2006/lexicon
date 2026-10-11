import LexiconDomain
import History

/// Which of a History row's actions work, apart from AppKit so tests can read
/// the rules. Play and Retry need the whole audio: once it aged out they are
/// greyed out and the text stays (#4). Pin, Retry and Delete change History, so
/// they need the running system (`canWrite`); none of them touches a Dictation
/// still in flight, which History would refuse to delete anyway, or one being retried.
struct RowActions {
    let play: Bool
    /// Pin to the Test set, which keeps the audio forever. A pinned row can always be unpinned.
    let pin: Bool
    let retry: Bool
    let delete: Bool

    init(_ row: HistoryRow, canWrite: Bool, retrying: Bool = false) {
        let settled = !row.status.isInFlight && !retrying
        play = row.hasAudio && row.status != .recording
        pin = canWrite && (row.pinned || row.hasAudio && settled)
        // A waiting Dictation is already retried, again and again, until it has text.
        retry = canWrite && row.hasAudio && settled && row.status != .waiting
        delete = canWrite && settled
    }

    /// The Retry picker: every model, cloud ones greyed out until the cloud race lands (M2).
    static var retryModels: [(model: SpeechModel, enabled: Bool)] {
        SpeechModel.allCases.map { model in
            switch model {
            case .local: (model, true)
            case .cloud: (model, false)
            }
        }
    }
}
