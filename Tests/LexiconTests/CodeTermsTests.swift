import Foundation
import Testing
import LexiconDomain
import WordStore

// Code Terms and the current repo, on fixture folders: a made-up `~/code` and
// home folder in a throwaway directory, real FSEvents, and made-up names only.
// Every wait is on an explicit signal (`CodeTerms.changes`); the deadline only
// stops a failing test from hanging.

/// A throwaway `~/code` and home folder.
private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "code-terms-\(UUID().uuidString)")
    var code: URL { root.appending(path: "code") }
    var home: URL { root.appending(path: "home") }

    init() throws {
        try FileManager.default.createDirectory(at: code, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Writes `text` at `path` below the fixture root, making folders.
    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    func remove(_ path: String) throws { try FileManager.default.removeItem(at: root.appending(path: path)) }

    /// A started CodeTerms over this fixture, feeding a fresh Lexicon.
    func start() async throws -> (CodeTerms, Lexicon) {
        let lexicon = try Lexicon(paths: .temporary())
        let terms = CodeTerms(code: code, home: home, lexicon: lexicon)
        await terms.start()
        return (terms, lexicon)
    }
}

/// True once `condition` holds, checked now and after each change; false after 10 s.
private func eventually(_ terms: CodeTerms, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    if await condition() { return true }
    return await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in terms.changes where await condition() { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
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
    try fixture.write("code/zorblax/GLOSSARY.md", "**Wobblecast**:\nA thing.\n\n**Dictation**:\nPlain English.\n")
    try fixture.write("code/zorblax/README.md", "Uses **Blorptastic** a lot.")
    try fixture.write("code/zorblax/.claude/skills/ship-zorb/SKILL.md")
    try fixture.write("code/zorblax/.claude/skills/not-a-skill/notes.md")
    try fixture.write("code/zorblax/.claude/commands/team/deploy.md")
    // A workspace two folders down counts; dependencies' own manifests and deeper ones don't.
    try fixture.write("code/zorblax/packages/web/package.json", """
        {"name": "zorblax-web", "scripts": {"dev": "vite"},
         "dependencies": {"zustand": "^4", "react": "^19", "@quux/frobnicate": "1"},
         "devDependencies": {"@types/node": "^22"}}
        """)
    try fixture.write("code/zorblax/node_modules/vorpal/package.json", #"{"dependencies": {"vorpalnode": "1"}}"#)
    try fixture.write("code/zorblax/a/b/c/package.json", #"{"dependencies": {"deepzork": "1"}}"#)
    // A plain-English repo name is no Term; its dependencies still are when it's current.
    try fixture.write("code/harbor/package.json", #"{"dependencies": {"grizzlebot": "1"}}"#)
    try fixture.write("code/quintrel/notes.txt")
    try fixture.write("home/.claude/skills/office-hours/SKILL.md")
    try fixture.write("home/.claude/skills/half-made/README.md")
    // `~/.agents/skills` entries are links into skill packs.
    try fixture.write("packs/qwopify/SKILL.md")
    try FileManager.default.createDirectory(at: fixture.home.appending(path: ".agents/skills"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fixture.home.appending(path: ".agents/skills/qwopify"),
                                               withDestinationURL: fixture.root.appending(path: "packs/qwopify"))

    let (terms, lexicon) = try await fixture.start()
    defer { Task { await terms.stop() } }
    try fixture.write("code/zorblax/Sources/ZorblaxKit/Flimmer.swift", "func snorkelWidget() {}")
    #expect(await current(terms, is: "zorblax"))
    #expect(await lexicon.codeTerms.map(\.text) == [
        "zorblax", "Wobblecast", "/ship-zorb", "/team:deploy", "FluidQuux", "@quux/frobnicate", "zustand",
        "/office-hours", "/qwopify", "quintrel",
    ])

    try fixture.write("code/harbor/index.js", "export const grizzle = 1")
    #expect(await current(terms, is: "harbor"))
    #expect(await lexicon.codeTerms.map(\.text) == ["grizzlebot", "/office-hours", "/qwopify", "quintrel", "zorblax"])
}

@Test func touchingAFileMakesItsRepoCurrent() async throws {
    let fixture = try Fixture()
    try fixture.write("code/quaxly/main.py")
    try fixture.write("code/zentrik/main.rs")
    try fixture.write("code/zentrik/.git/HEAD")
    // Only skill folders there at launch are watched.
    try fixture.write("home/.claude/skills/old-skill/SKILL.md")
    let (terms, lexicon) = try await fixture.start()
    defer { Task { await terms.stop() } }

    try fixture.write("code/zentrik/main.rs", "fn main() {}")
    #expect(await current(terms, is: "zentrik"))
    #expect(await lexicon.codeTerms.first?.text == "zentrik")
    try fixture.write("code/quaxly/main.py", "print()")
    #expect(await current(terms, is: "quaxly"))
    #expect(await lexicon.codeTerms.first?.text == "quaxly")

    // Git's own writes (a background fetch, `git status`) are not Jake changing a
    // file. The skill added after it is the signal that both were seen.
    try fixture.write("code/zentrik/.git/FETCH_HEAD", "abc")
    try fixture.write("home/.claude/skills/fresh-skill/SKILL.md")
    #expect(await eventually(terms) { await lexicon.codeTerms.contains(Term(text: "/fresh-skill")) })
    #expect(await terms.currentRepo == "quaxly")
}

@Test func atLaunchTheRepoChangedLastIsCurrent() async throws {
    let fixture = try Fixture()
    try fixture.write("code/quaxly/main.py")
    try fixture.write("code/zentrik/main.rs")
    // A first watcher seeing zentrik's change is the signal that FSEvents has it.
    let (first, _) = try await fixture.start()
    try fixture.write("code/zentrik/main.rs", "fn main() {}")
    #expect(await current(first, is: "zentrik"))
    await first.stop()

    // A relaunch replays recent history before `start()` returns.
    let (relaunched, lexicon) = try await fixture.start()
    defer { Task { await relaunched.stop() } }
    #expect(await relaunched.currentRepo == "zentrik")
    #expect(await lexicon.codeTerms.first?.text == "zentrik")
}

@Test func theNamesFollowTheFiles() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zentrik/package.json", #"{"dependencies": {"blorpkit": "1"}}"#)
    let (terms, lexicon) = try await fixture.start()
    defer { Task { await terms.stop() } }
    try fixture.write("code/zentrik/index.js")
    #expect(await current(terms, is: "zentrik"))
    #expect(await lexicon.codeTerms.map(\.text) == ["zentrik", "blorpkit"])

    try fixture.write("code/zentrik/package.json", #"{"dependencies": {"snazzle": "1"}}"#)
    #expect(await eventually(terms) { await lexicon.codeTerms.map(\.text) == ["zentrik", "snazzle"] })
    try fixture.write("code/zentrik/GLOSSARY.md", "**Quibblet**: a word.")
    #expect(await eventually(terms) { await lexicon.codeTerms.map(\.text) == ["zentrik", "Quibblet", "snazzle"] })

    // A new repo is found and becomes current; a deleted one leaves no Terms behind.
    try fixture.write("code/vexmo/main.go")
    #expect(await current(terms, is: "vexmo"))
    #expect(await lexicon.codeTerms.map(\.text) == ["vexmo", "zentrik"])
    try fixture.remove("code/vexmo")
    #expect(await current(terms, is: nil))
    #expect(await lexicon.codeTerms.map(\.text) == ["zentrik"])
}
