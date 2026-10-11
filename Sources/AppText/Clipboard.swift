import AppKit

/// What a pasteboard held, copied out so it can be put back: every item, every
/// type, in order. Empty when the pasteboard was empty.
struct PasteboardContents: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let type: String
        let data: Data
    }
    var items: [[Entry]]
}

/// The pasteboard as the paste needs it. `SystemPasteboard` is the real one;
/// tests use a fake.
@MainActor protocol Clipboard: AnyObject {
    var changeCount: Int { get }
    /// Reading another app's data. On macOS 26 this is the read that can ask Jake first.
    func contents() -> PasteboardContents
    /// Clears the pasteboard and promises `text`. `onRead` runs each time a
    /// reader asks for the text. Returns the change count after the write.
    func promise(_ text: String, onRead: @escaping @MainActor () -> Void) -> Int
    func write(_ contents: PasteboardContents)
}

/// Owns the pasteboard from Lexicon's write until Jake's clipboard is back,
/// Handy-style: the text goes up as a promise, the target's read of it is the
/// receipt that the paste landed, and the previous clipboard is restored once
/// reads have been quiet for 200 ms, at most 8 s after the write, and only if
/// nobody wrote the pasteboard since (`changeCount`), so a restore never
/// overwrites something Jake copied in between. No read within 1 s means the
/// paste did not land: the text is withdrawn at once (the clipboard goes back),
/// so it can never appear after History was told it didn't.
///
/// Time comes in as arguments, so the rules are tested with explicit instants;
/// `TargetApp` drives `expire` from a real timer.
@MainActor final class ClipboardKeeper {
    typealias Instant = ContinuousClock.Instant

    static let quiet: Duration = .milliseconds(200)
    static let cap: Duration = .seconds(8)
    static let receiptWait: Duration = .seconds(1)

    struct PasteID: Hashable, Sendable { let value: Int }

    enum Expiry: Equatable {
        /// No read in time: the paste did not land, and the clipboard is back.
        case missed(PasteID)
        /// Reads went quiet (or the cap passed): the clipboard is back, unless Jake copied since.
        case settled(PasteID)
    }

    private struct Saved {
        let contents: PasteboardContents
        let changeCount: Int
    }

    private struct Current {
        let id: PasteID
        let changeCount: Int
        let putAt: Instant
        var lastRead: Instant?
    }

    private let pasteboard: any Clipboard
    private let now: @MainActor () -> Instant
    /// Jake's clipboard while Lexicon owns the pasteboard (or read ahead by `prefetch`).
    private var saved: Saved?
    private var current: Current?
    private var serial = 0
    private var waiters: [PasteID: [CheckedContinuation<Bool, Never>]] = [:]
    private var receipts: [PasteID: Bool] = [:]
    /// After each read of the current paste: the deadline may have moved.
    var onRead: (@MainActor () -> Void)?

    init(pasteboard: any Clipboard, now: @escaping @MainActor () -> Instant = { .now }) {
        self.pasteboard = pasteboard
        self.now = now
    }

    /// Reads Jake's clipboard ahead of the paste (at fn-up), so the read is off
    /// the path from text ready to Cmd-V. A no-op while the pasteboard still
    /// holds Lexicon's text or nothing changed since the last read.
    func prefetch() {
        let count = pasteboard.changeCount
        if let current, current.changeCount == count { return }
        if saved?.changeCount == count { return }
        saved = Saved(contents: pasteboard.contents(), changeCount: count)
    }

    /// Puts `text` up as a promise. Back to back pastes keep the clipboard Jake
    /// had before the first one: the pasteboard then still holds our own text.
    func put(_ text: String) -> PasteID {
        if let current {
            // Superseded. While the pasteboard still holds its text, `saved` stays Jake's.
            settle(current.id, receipt: current.lastRead != nil)
            self.current = current.changeCount == pasteboard.changeCount ? current : nil
        }
        prefetch()
        serial += 1
        let id = PasteID(value: serial)
        let count = pasteboard.promise(text) { [weak self] in self?.didRead(id) }
        current = Current(id: id, changeCount: count, putAt: now(), lastRead: nil)
        return id
    }

    /// When `expire` next has something to do.
    var deadline: Instant? {
        guard let current else { return nil }
        guard let lastRead = current.lastRead else { return current.putAt + Self.receiptWait }
        return min(lastRead + Self.quiet, current.putAt + Self.cap)
    }

    /// Runs whatever is due at `at`. nil when nothing is.
    func expire(at instant: Instant) -> Expiry? {
        guard let current, let deadline, instant >= deadline else { return nil }
        let receipt = current.lastRead != nil
        restore(current)
        settle(current.id, receipt: receipt)
        return receipt ? .settled(current.id) : .missed(current.id)
    }

    /// True once the target read the text, false once it missed; waits until one happens.
    func receipt(_ id: PasteID) async -> Bool {
        if let known = receipts[id] { return known }
        if current?.id != id { return false }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    private func didRead(_ id: PasteID) {
        guard current?.id == id else { return }  // withdrawn or superseded
        current?.lastRead = now()
        if receipts[id] == nil { resolve(id, true) }
        onRead?()
    }

    private func restore(_ current: Current) {
        self.current = nil
        defer { saved = nil }
        guard pasteboard.changeCount == current.changeCount, let saved else { return }
        pasteboard.write(saved.contents)
    }

    private func settle(_ id: PasteID, receipt: Bool) {
        if receipts[id] == nil { resolve(id, receipt) }
        receipts = receipts.filter { $0.key.value > id.value - 8 }  // only recent pastes are ever asked about
    }

    private func resolve(_ id: PasteID, _ value: Bool) {
        receipts[id] = value
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume(returning: value) }
    }
}

/// `NSPasteboard` behind `Clipboard`.
@MainActor final class SystemPasteboard: Clipboard {
    /// Conventions (nspasteboard.org) that tell clipboard managers to skip our
    /// text, so fewer eager readers fake a receipt. Set as empty data, never promised.
    static let markers = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
                          "org.nspasteboard.AutoGeneratedType"].map { NSPasteboard.PasteboardType($0) }

    private let board: NSPasteboard
    private var provider: Provider?

    init(_ board: NSPasteboard = .general) { self.board = board }

    var changeCount: Int { board.changeCount }

    func contents() -> PasteboardContents {
        PasteboardContents(items: (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { .init(type: type.rawValue, data: $0) } }
        })
    }

    func promise(_ text: String, onRead: @escaping @MainActor () -> Void) -> Int {
        // This host only: a dictation is not for Universal Clipboard on Jake's phone.
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        let provider = Provider(text: text, onRead: onRead)
        item.setDataProvider(provider, forTypes: [.string])
        for marker in Self.markers { item.setData(Data(), forType: marker) }
        board.writeObjects([item])
        self.provider = provider  // the item holds its provider weakly
        return board.changeCount
    }

    func write(_ contents: PasteboardContents) {
        provider = nil
        board.clearContents()
        let items = contents.items.map { entries in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: .init(entry.type)) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }

    /// Answers the promise. AppKit calls it on the main thread, from the run
    /// loop, when a reader first asks for the text; the pasteboard server keeps
    /// the data after that, so later reads of the same paste do not call it again.
    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        let text: String
        let onRead: @MainActor () -> Void

        init(text: String, onRead: @escaping @MainActor () -> Void) {
            self.text = text
            self.onRead = onRead
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            let onRead = onRead
            if Thread.isMainThread {
                MainActor.assumeIsolated { onRead() }
            } else {
                // Not seen on macOS 26; a late receipt beats a crash in Jake's app.
                Task { @MainActor in onRead() }
            }
        }
    }
}
