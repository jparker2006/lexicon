public import Foundation
import LexiconDomain
import CoreServices

/// Names from Jake's code, held as Terms in memory and never stored: repo names
/// under `~/code`, their dependency names, skill and slash-command names, and bold
/// GLOSSARY.md terms (`CodeScan`). Also decides the current repo: the repo under
/// `~/code` with the most recent file change. No hooks.
///
/// Scans everything at `start()`, then follows FSEvents on the code folder and the
/// home skill folders there at launch (watching all of `~/.claude` would wake
/// Lexicon on every Claude Code transcript write): a change in a repo makes it current, and a change to a
/// manifest, GLOSSARY.md or a skill folder reads that repo again. Each time the
/// current repo's code Terms change they go to the Lexicon, so a Dictation's
/// fn-down only copies them.
public actor CodeTerms {
    /// The current repo after each change to it or to its code Terms. Keeps only
    /// the newest value, so nobody reading it costs nothing.
    public nonisolated let changes: AsyncStream<String?>
    /// Changes only once the Lexicon holds this repo's code Terms.
    public private(set) var currentRepo: String?

    private let code: URL
    private let home: URL
    private let lexicon: Lexicon
    private let changed: AsyncStream<String?>.Continuation
    /// Real paths (symlinks resolved), as FSEvents reports them.
    private var codeRoot: String?
    private var homeFolders: [String] = []
    private var index = CodeIndex()
    private var published: (repo: String?, terms: [Term])?
    private var events: FileEvents?
    private var reader: Task<Void, Never>?
    private var replay: CheckedContinuation<Void, Never>?
    private var replayed = false
    private var pending = Pending()

    /// What events changed since they were last applied.
    private struct Pending {
        var repos = Set<String>()
        var user = false
        var everything = false
        /// The repo of the newest content change.
        var newest: String?
    }

    /// How far back launch looks for the most recent file change: a weekend away
    /// still finds the repo Jake left. A week of `~/code` replays in about 1 s.
    static let history: TimeInterval = 7 * 24 * 3600
    /// FSEvents coalescing: a touched file makes its repo current well within a second.
    static let latency: TimeInterval = 0.2
    /// Launch never waits longer than this for the replay; later events still count.
    static let replayDeadline: Duration = .seconds(5)

    public init(code: URL, home: URL, lexicon: Lexicon) {
        self.code = code
        self.home = home
        self.lexicon = lexicon
        (changes, changed) = AsyncStream.makeStream(of: String?.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Scans, hands the Lexicon its code Terms, starts watching, and returns once
    /// the recent history has picked the current repo (or the deadline passed).
    public func start() async {
        guard events == nil else { return }
        codeRoot = Self.realPath(code)
        homeFolders = CodeScan.skillFolders.compactMap { Self.realPath(home.appending(path: $0)) }
        index = CodeScan.scan(code: codeRoot.map { URL(filePath: $0) }, home: home)
        await publish(current: currentRepo)

        let paths = [codeRoot].compactMap { $0 } + homeFolders
        let since = codeRoot.map { FileEvents.lastEvent(on: $0, before: Self.history) }
            ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        let (batches, deliver) = AsyncStream.makeStream(of: [FileEvent].self)
        guard !paths.isEmpty, let events = FileEvents(paths: paths, since: since, latency: Self.latency,
                                                      deliver: deliver) else { return }
        self.events = events
        reader = Task { [weak self] in
            for await batch in batches { await self?.handle(batch) }
        }
        guard since != FSEventStreamEventId(kFSEventStreamEventIdSinceNow), !replayed else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.replayDeadline)
            await self?.replayDeadlinePassed()
        }
        await withCheckedContinuation { replay = $0 }
    }

    public func stop() {
        events = nil
        reader?.cancel()
        reader = nil
        endReplay()
    }

    private func handle(_ batch: [FileEvent]) async {
        var historyDone = false
        for event in batch {
            if event.isHistoryDone {
                historyDone = true
                continue
            }
            if event.mustRescan { pending.everything = true }
            if let root = codeRoot, let components = Self.components(of: event.path, below: root) {
                guard let repo = components.first, !repo.hasPrefix("."), !components.contains(".git") else { continue }
                if event.changesContent { pending.newest = String(repo) }
                if CodeScan.changesNames(Array(components.dropFirst())) { pending.repos.insert(String(repo)) }
            } else if homeFolders.contains(where: { Self.components(of: event.path, below: $0) != nil }) {
                pending.user = true
            }
        }
        // While history replays, only note what changed: a week of builds would
        // read the same repos again for every batch.
        guard replayed || historyDone else { return }
        await apply()
        // Only now: `start()` returns with the replayed repo already in the Lexicon.
        if historyDone { endReplay() }
    }

    /// Reads again what changed, moves the current repo, and tells the Lexicon.
    private func apply() async {
        let changes = pending
        pending = Pending()
        if changes.everything {
            index = CodeScan.scan(code: codeRoot.map { URL(filePath: $0) }, home: home)
        } else {
            for repo in changes.repos { rescan(repo) }
            if changes.user { index.user = CodeScan.skillNames(in: home) }
        }
        var current = currentRepo
        if let newest = changes.newest, index.repos[newest] != nil { current = newest }
        if let repo = current, index.repos[repo] == nil { current = nil }
        await publish(current: current)
    }

    private func replayDeadlinePassed() async {
        guard !replayed else { return }
        replayed = true
        await apply()
        endReplay()
    }

    private func rescan(_ repo: String) {
        guard let root = codeRoot else { return }
        let url = URL(filePath: root).appending(path: repo)
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            index.repos[repo] = CodeScan.names(ofRepo: url)
        } else {
            index.repos[repo] = nil
        }
    }

    private func publish(current: String?) async {
        let terms = index.terms(current: current)
        if let published, published.repo == current, published.terms == terms { return }
        published = (current, terms)
        await lexicon.useCodeTerms(terms)
        currentRepo = current
        changed.yield(current)
    }

    private func endReplay() {
        replayed = true
        replay?.resume()
        replay = nil
    }

    /// The path's components below `root`, or nil when it is not inside it. The
    /// root itself has none.
    static func components(of path: String, below root: String) -> [Substring]? {
        guard path.hasPrefix(root) else { return nil }
        let rest = path.dropFirst(root.count)
        guard rest.isEmpty || rest.hasPrefix("/") else { return nil }
        return rest.split(separator: "/")
    }

    /// FSEvents reports real paths: `/var` is `/private/var`, and `~/code` may be a link.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// One FSEvents change: a real path and what happened to it.
struct FileEvent: Sendable {
    let path: String
    let flags: FSEventStreamEventFlags

    var isHistoryDone: Bool { has(kFSEventStreamEventFlagHistoryDone) }
    /// Events were dropped or coalesced past one folder: read everything again.
    var mustRescan: Bool { has(kFSEventStreamEventFlagMustScanSubDirs) || has(kFSEventStreamEventFlagRootChanged) }
    /// A file or folder was created, removed, renamed, written or touched. An
    /// extended attribute alone (Spotlight, quarantine) is not Jake changing a file.
    var changesContent: Bool {
        has(kFSEventStreamEventFlagItemCreated) || has(kFSEventStreamEventFlagItemRemoved)
            || has(kFSEventStreamEventFlagItemRenamed) || has(kFSEventStreamEventFlagItemModified)
            || has(kFSEventStreamEventFlagItemInodeMetaMod)
    }

    private func has(_ flag: Int) -> Bool { flags & FSEventStreamEventFlags(flag) != 0 }
}

/// An FSEvents stream with file-level events, delivered in order as batches.
/// Stops when released.
final class FileEvents {
    /// What the C callback holds: only the continuation, which is Sendable.
    private final class Sink: Sendable {
        let deliver: AsyncStream<[FileEvent]>.Continuation
        init(_ deliver: AsyncStream<[FileEvent]>.Continuation) { self.deliver = deliver }
    }

    private let stream: FSEventStreamRef
    private let sink: Sink

    /// `since` replays the events after that ID first, ending with a HistoryDone event.
    init?(paths: [String], since: FSEventStreamEventId, latency: TimeInterval,
          deliver: AsyncStream<[FileEvent]>.Continuation) {
        let sink = Sink(deliver)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(sink).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let sink = Unmanaged<Sink>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            sink.deliver.yield((0..<count).map { FileEvent(path: paths[$0], flags: flags[$0]) })
        }
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since, latency,
                                               FSEventStreamCreateFlags(flags)) else { return nil }
        self.stream = stream
        self.sink = sink
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "lexicon.code-terms.events"))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    deinit {
        // Stop and invalidate before the sink goes: no callback can run after this.
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        sink.deliver.finish()
    }

    /// The last event on `path`'s volume before `window` ago. 0 when the volume's
    /// history is younger than that, which replays all of it.
    static func lastEvent(on path: String, before window: TimeInterval) -> FSEventStreamEventId {
        var info = stat()
        guard stat(path, &info) == 0 else { return FSEventStreamEventId(kFSEventStreamEventIdSinceNow) }
        return FSEventsGetLastEventIdForDeviceBeforeTime(info.st_dev, CFAbsoluteTimeGetCurrent() - window)
    }
}
