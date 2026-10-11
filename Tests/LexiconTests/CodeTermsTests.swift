import CoreServices
import Foundation
import Synchronization
import Testing
import LexiconDomain
@testable import WordStore

// Code Terms and the current repo, on fixture folders: a made-up `~/code` and
// home folder in a throwaway directory, and made-up names only. Each change to
// the fixture also goes to a scripted file-event source as the events FSEvents
// reports for it, so no test waits on FSEvents (the smoke test at the end does,
// once). Every wait is on an explicit signal (`CodeTerms.changes`), and each
// touch goes to a repo that is not current yet, so the wait is real. The
// deadline only stops a failing test from hanging. The scripted replay ends with
// HistoryDone at once, so CodeTerms' replay deadline decides no result either.

/// File events the fixture sends, delivered the moment it sends them. Like
/// FSEvents, a watch with history first replays every event sent before it,
/// then HistoryDone.
private final class ScriptedFileEvents: FileEventSource {
    private struct Watch {
        let paths: [String]
        let ignoring: @Sendable (String) -> Bool
        let deliver: AsyncStream<[FileEvent]>.Continuation

        /// Hands on the events FSEvents would: HistoryDone, which has no path here, and
        /// those on a watched path that `isKept` keeps.
        func send(_ events: [FileEvent]) {
            let kept = events.filter { event in
                event.isHistoryDone
                    || (event.isKept(ignoring: ignoring)
                        && paths.contains { event.path == $0 || event.path.hasPrefix($0 + "/") })
            }
            if !kept.isEmpty { deliver.yield(kept) }
        }
    }

    private let state = Mutex<(sent: [FileEvent], watch: Watch?)>(([], nil))

    func watch(_ paths: [String], historyOn volume: String?, ignoring: @escaping @Sendable (String) -> Bool,
               deliver: AsyncStream<[FileEvent]>.Continuation) -> FileWatch? {
        let watch = Watch(paths: paths, ignoring: ignoring, deliver: deliver)
        state.withLock { state in
            state.watch = watch
            if volume != nil {
                watch.send(state.sent)
                watch.send([FileEvent(path: "", flags: flags(kFSEventStreamEventFlagHistoryDone))])
            }
        }
        return FileWatch(replays: volume != nil, running: self)
    }

    func send(_ events: [FileEvent]) {
        state.withLock { state in
            state.sent += events
            state.watch?.send(events)
        }
    }
}

private func flags(_ flags: Int...) -> FSEventStreamEventFlags {
    FSEventStreamEventFlags(flags.reduce(0, |))
}

/// A throwaway `~/code` and home folder.
private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "code-terms-\(UUID().uuidString)")
    /// `root` as FSEvents reports it: `/var` is `/private/var`.
    let realRoot: String
    let events = ScriptedFileEvents()
    var code: URL { root.appending(path: "code") }
    var home: URL { root.appending(path: "home") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "code"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        realRoot = try #require(CodeTerms.realPath(root))
    }

    /// Writes `text` at `path` below the fixture root, making folders.
    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        var made = try makeFolders(url.deletingLastPathComponent())
        let existed = FileManager.default.fileExists(atPath: url.path)
        try text.write(to: url, atomically: false, encoding: .utf8)
        let created = existed ? 0 : kFSEventStreamEventFlagItemCreated
        made.append(event(path, flags(created, kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile)))
        events.send(made)
    }

    /// Makes the folder at `path` and any missing above it.
    func makeFolder(_ path: String) throws {
        events.send(try makeFolders(root.appending(path: path)))
    }

    /// Removes the file or folder at `path`. FSEvents reports each file and folder
    /// removed, deepest first.
    func remove(_ path: String) throws {
        let below = (try? FileManager.default.subpathsOfDirectory(atPath: root.appending(path: path).path)) ?? []
        let removed = ([path] + below.map { "\(path)/\($0)" }).sorted().reversed().map { path in
            event(path, flags(kFSEventStreamEventFlagItemRemoved, kind(of: path)))
        }
        try FileManager.default.removeItem(at: root.appending(path: path))
        events.send(removed)
    }

    /// FSEvents reports a move as a rename of both paths, never of what is inside.
    func move(_ path: String, to destination: String) throws {
        let kind = kind(of: path)
        try FileManager.default.moveItem(at: root.appending(path: path), to: root.appending(path: destination))
        events.send([path, destination].map { event($0, flags(kFSEventStreamEventFlagItemRenamed, kind)) })
    }

    /// A started CodeTerms over this fixture's scripted events, feeding a fresh Lexicon.
    func start() async throws -> (CodeTerms, Lexicon) {
        let lexicon = try Lexicon(paths: .temporary())
        let terms = CodeTerms(code: code, home: home, lexicon: lexicon, source: events)
        await terms.start()
        return (terms, lexicon)
    }

    /// Stops the watcher and deletes the folders.
    func finish(_ terms: CodeTerms) async {
        await terms.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `url` and the missing folders above it, and returns their events, outermost first.
    private func makeFolders(_ url: URL) throws -> [FileEvent] {
        var missing: [URL] = []
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path) {
            missing.insert(folder, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return missing.map { folder in
            let path = String(folder.path.dropFirst(root.path.count + 1))
            return event(path, flags(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsDir))
        }
    }

    private func kind(of path: String) -> Int {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: root.appending(path: path).path, isDirectory: &isFolder)
        return isFolder.boolValue ? kFSEventStreamEventFlagItemIsDir : kFSEventStreamEventFlagItemIsFile
    }

    private func event(_ path: String, _ flags: FSEventStreamEventFlags) -> FileEvent {
        FileEvent(path: "\(realRoot)/\(path)", flags: flags)
    }
}

/// True once `condition` holds, checked now and after each change; false after
/// 120 s. The limit only stops a failing test from hanging: on a loaded 3-core CI
/// runner a test can wait over 10 s for a thread.
private func eventually(_ terms: CodeTerms, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    if await condition() { return true }
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in terms.changes where await condition() { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(120))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

private func current(_ terms: CodeTerms, is repo: String?) async -> Bool {
    await eventually(terms) { await terms.currentRepo == repo }
}

@Test func codeTermsAreNamesNeverIdentifiersOrFileNames() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zorblax/Package.swift", """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "ZorblaxApp",
            dependencies: [.package(url: "https://github.com/quux/FluidQuux.git", from: "1.0.0")],
            targets: [.target(name: "ZorblaxKit", dependencies: [.product(name: "QuuxCore", package: "FluidQuux")])]
        )
        """)
    try fixture.write("code/zorblax/Sources/ZorblaxKit/Flimmer.swift", "func snorkelWidget() { let gribbleCount = 3 }")
    try fixture.write("code/zorblax/GLOSSARY.md", """
        **Wobblecast**:
        A thing.

        ***Plimsoft***: emphasis around a term. **Dictation**: plain English.
        Run `a ** b` or `c ** d`, and **n** is a single letter.
        """)
    try fixture.write("code/zorblax/README.md", "Uses **Blorptastic** a lot.")
    try fixture.write("code/zorblax/.claude/skills/ship-zorb/SKILL.md")
    try fixture.write("code/zorblax/.claude/skills/not-a-skill/notes.md")
    try fixture.write("code/zorblax/.claude/commands/team/deploy.md")
    // A workspace two folders down counts; dependencies' own manifests, deeper
    // ones and examples don't.
    try fixture.write("code/zorblax/packages/web/package.json", """
        {"name": "zorblax-web", "scripts": {"dev": "vexbuild"},
         "dependencies": {"zorbstand": "^4", "lantern": "^19", "@quux/frobnicate": "1"},
         "devDependencies": {"@types/node": "^22"}}
        """)
    try fixture.write("code/zorblax/node_modules/vorpal/package.json", #"{"dependencies": {"vorpalnode": "1"}}"#)
    try fixture.write("code/zorblax/a/b/c/package.json", #"{"dependencies": {"deepzork": "1"}}"#)
    try fixture.write("code/zorblax/examples/demo/package.json", #"{"dependencies": {"demozork": "1"}}"#)
    try fixture.write("code/quintrel/notes.txt")
    // A plain-English repo name is no Term; its dependencies still are when it's current.
    try fixture.write("code/harbor/package.json", #"{"dependencies": {"grizzlebot": "1"}}"#)
    try fixture.write("home/.claude/skills/plonk-hours/SKILL.md")
    try fixture.write("home/.claude/skills/half-made/README.md")
    // `~/.agents/skills` entries are links into skill packs.
    try fixture.write("packs/qwopify/SKILL.md")
    try FileManager.default.createDirectory(at: fixture.home.appending(path: ".agents/skills"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: ".agents/skills/qwopify"),
                                               withDestinationURL: fixture.root.appending(path: "packs/qwopify"))

    let (terms, lexicon) = try await fixture.start()
    try fixture.write("code/quintrel/notes.txt", "settle on another repo first")
    #expect(await current(terms, is: "quintrel"))
    #expect(await lexicon.codeTerms.map(\.text) == ["quintrel", "/plonk-hours", "/qwopify"])

    try fixture.write("code/zorblax/Sources/ZorblaxKit/Flimmer.swift", "func snorkelWidget() {}")
    #expect(await current(terms, is: "zorblax"))
    // Other repos' names stay on the Mac: only the current repo's go to the models.
    #expect(await lexicon.codeTerms.map(\.text) == [
        "zorblax", "Wobblecast", "Plimsoft", "/ship-zorb", "/team:deploy", "FluidQuux", "@quux/frobnicate",
        "zorbstand", "/plonk-hours", "/qwopify",
    ])

    try fixture.write("code/harbor/index.js", "export const grizzle = 1")
    #expect(await current(terms, is: "harbor"))
    #expect(await lexicon.codeTerms.map(\.text) == ["grizzlebot", "/plonk-hours", "/qwopify"])
    await fixture.finish(terms)
}

@Test func touchingAFileMakesItsRepoCurrent() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zentrik/main.rs")
    try fixture.write("code/zentrik/.git/HEAD")
    try fixture.write("code/quaxly/main.py")
    // A repo may be named like a build folder; only folders inside a repo are output.
    try fixture.write("code/dist/main.c")
    // Only skill folders there at launch are watched.
    try fixture.write("home/.claude/skills/old-skill/SKILL.md")
    let (terms, lexicon) = try await fixture.start()

    // Each touch goes to the repo the last one left behind.
    for repo in ["zentrik", "dist", "quaxly", "zentrik"] {
        try fixture.write("code/\(repo)/main.txt", repo)
        #expect(await current(terms, is: repo))
        #expect(await lexicon.codeTerms.first?.text == repo)
    }

    // Git's own writes (a background fetch, `git status`) and build output are not
    // Jake changing a file. The skill added after them is the signal they were seen.
    try fixture.write("code/quaxly/.git/FETCH_HEAD", "abc")
    try fixture.write("code/quaxly/.build/debug/quaxly.o", "abc")
    try fixture.write("code/quaxly/node_modules/glorp/index.js", "abc")
    try fixture.write("home/.claude/skills/fresh-skill/SKILL.md")
    #expect(await eventually(terms) { await lexicon.codeTerms.contains(Term(text: "/fresh-skill")) })
    #expect(await terms.currentRepo == "zentrik")
    await fixture.finish(terms)
}

@Test func atLaunchTheRepoChangedLastIsCurrent() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zentrik/main.rs")
    try fixture.write("code/quaxly/main.py")
    try fixture.write("code/vexmo/main.go")
    try fixture.write("code/quaxly/main.py", "print()")
    // Nothing changes after launch, so only the replay of recent history can make quaxly current.
    let (terms, lexicon) = try await fixture.start()
    #expect(await current(terms, is: "quaxly"))
    #expect(await lexicon.codeTerms.first?.text == "quaxly")
    await fixture.finish(terms)
}

@Test func theNamesFollowTheFiles() async throws {
    let fixture = try Fixture()
    try fixture.write("code/quaxly/main.py")
    try fixture.write("code/zentrik/package.json", #"{"dependencies": {"blorpkit": "1"}}"#)
    try fixture.write("code/zentrik/packages/web/package.json", #"{"dependencies": {"webzork": "1"}}"#)
    let (terms, lexicon) = try await fixture.start()
    try fixture.write("code/quaxly/main.py", "print()")
    #expect(await current(terms, is: "quaxly"))
    try fixture.write("code/zentrik/index.js")
    #expect(await current(terms, is: "zentrik"))
    #expect(await lexicon.codeTerms.map(\.text) == ["zentrik", "blorpkit", "webzork"])

    try fixture.write("code/zentrik/package.json", #"{"dependencies": {"snazzle": "1"}}"#)
    #expect(await eventually(terms) { await lexicon.codeTerms.map(\.text) == ["zentrik", "snazzle", "webzork"] })
    try fixture.write("code/zentrik/GLOSSARY.md", "**Quibblet**: a word.")
    #expect(await eventually(terms) {
        await lexicon.codeTerms.map(\.text) == ["zentrik", "Quibblet", "snazzle", "webzork"]
    })
    // Moving a workspace deeper than manifests are read takes its names along, though
    // FSEvents reports only the folders, never the manifest inside.
    try fixture.makeFolder("code/zentrik/old/attic")
    try fixture.move("code/zentrik/packages", to: "code/zentrik/old/attic/packages")
    #expect(await eventually(terms) { await lexicon.codeTerms.map(\.text) == ["zentrik", "Quibblet", "snazzle"] })

    // A new repo is found and becomes current; a deleted one leaves no Terms behind.
    try fixture.write("code/vexmo/main.go")
    #expect(await current(terms, is: "vexmo"))
    #expect(await lexicon.codeTerms.map(\.text) == ["vexmo"])
    try fixture.remove("code/vexmo")
    #expect(await current(terms, is: nil))
    #expect(await lexicon.codeTerms.isEmpty)
    await fixture.finish(terms)
}

@Test func withNoCodeFolderHomeSkillsStillFollowTheFiles() async throws {
    let fixture = try Fixture()
    try fixture.remove("code")
    try fixture.write("home/.claude/skills/old-skill/SKILL.md")
    let (terms, lexicon) = try await fixture.start()
    #expect(await lexicon.codeTerms.map(\.text) == ["/old-skill"])

    try fixture.write("home/.claude/skills/fresh-skill/SKILL.md")
    #expect(await eventually(terms) { await lexicon.codeTerms.map(\.text) == ["/fresh-skill", "/old-skill"] })
    #expect(await terms.currentRepo == nil)
    await fixture.finish(terms)
}

// The one test on real FSEvents, through the app's own path: a write in the
// fixture reaches CodeTerms with real paths (`/private/var`) and the created and
// modified flags FSEvents sets. It runs on CI only: on a Mac busy with builds,
// fseventsd can lag past a minute (7 of 19 runs here, at load average 25 to 48),
// and the local check must not go red for that. Each write goes to the repo that
// is not current.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] != nil), .timeLimit(.minutes(4)))
func fsEventsReachCodeTerms() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zentrik/main.rs")
    try fixture.write("code/quaxly/main.py")
    let lexicon = try Lexicon(paths: .temporary())
    let terms = CodeTerms(code: fixture.code, home: fixture.home, lexicon: lexicon)
    await terms.start()
    for repo in ["zentrik", "quaxly"] {
        try fixture.write("code/\(repo)/main.txt", repo)
        #expect(await current(terms, is: repo), """
            No write reached CodeTerms through real FSEvents in 120 s. A very busy Mac can stall \
            fseventsd this long; on an idle one, look at FSEventsSource and the real paths.
            """)
    }
    await fixture.finish(terms)
}
