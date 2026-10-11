import Foundation
import Testing
import LexiconDomain
import WordStore

// Code Terms and the current repo, on fixture folders: a made-up `~/code` and
// home folder in a throwaway directory, real FSEvents, and made-up names only.
// Every wait is on an explicit signal (`CodeTerms.changes`), and each touch goes
// to a repo that is not current yet, so the wait is real. The deadline only
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

    func move(_ path: String, to destination: String) throws {
        try FileManager.default.moveItem(at: root.appending(path: path), to: root.appending(path: destination))
    }

    /// A started CodeTerms over this fixture, feeding a fresh Lexicon.
    func start() async throws -> (CodeTerms, Lexicon) {
        let lexicon = try Lexicon(paths: .temporary())
        let terms = CodeTerms(code: code, home: home, lexicon: lexicon)
        await terms.start()
        return (terms, lexicon)
    }

    /// Stops the watcher and deletes the folders.
    func finish(_ terms: CodeTerms) async {
        await terms.stop()
        try? FileManager.default.removeItem(at: root)
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
    // A plain-English repo name is no Term; its dependencies still are when it's current.
    try fixture.write("code/harbor/package.json", #"{"dependencies": {"grizzlebot": "1"}}"#)
    try fixture.write("code/quintrel/notes.txt")
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
    // A first watcher seeing zentrik's change is the signal that FSEvents has it.
    let (first, _) = try await fixture.start()
    try fixture.write("code/zentrik/main.rs", "fn main() {}")
    #expect(await current(first, is: "zentrik"))
    await first.stop()

    // Nothing changes after this, so only the replay of recent history can make zentrik current.
    let (relaunched, lexicon) = try await fixture.start()
    #expect(await current(relaunched, is: "zentrik"))
    #expect(await lexicon.codeTerms.first?.text == "zentrik")
    await fixture.finish(relaunched)
}

@Test func theNamesFollowTheFiles() async throws {
    let fixture = try Fixture()
    try fixture.write("code/zentrik/package.json", #"{"dependencies": {"blorpkit": "1"}}"#)
    try fixture.write("code/zentrik/packages/web/package.json", #"{"dependencies": {"webzork": "1"}}"#)
    try fixture.write("code/quaxly/main.py")
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
    try FileManager.default.createDirectory(at: fixture.code.appending(path: "zentrik/old/attic"),
                                            withIntermediateDirectories: true)
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
