import Foundation
import LexiconDomain

/// The names one repo under `~/code` gives the Lexicon, plain-English ones
/// already dropped. Names only: never an identifier or a file name.
struct RepoNames: Sendable, Equatable {
    /// The repo's folder name, or nil when it is plain English.
    var name: String?
    /// Bold terms in the repo's root GLOSSARY.md.
    var glossary: [String] = []
    /// The repo's own skills and slash commands, as "/name".
    var skills: [String] = []
    /// Names from Package.swift, package.json, Cargo.toml and pyproject.toml.
    var dependencies: [String] = []
}

/// Every code name found: each repo's, plus the skills and slash commands in
/// the home folder, which apply in every repo.
struct CodeIndex: Sendable, Equatable {
    var repos: [String: RepoNames] = [:]
    var user: [String] = []

    /// The current repo's code Terms in the order selection cuts them: the repo's
    /// name, its glossary, its skills and commands, its dependencies, then the
    /// skills and commands from the home folder, which work in every repo. With no
    /// current repo, only those. Other repos' names stay on the Mac: the models
    /// see only the current repo's. The same name twice, in any case, is kept
    /// once, where it first appears.
    func terms(current: String?) -> [Term] {
        var names: [String] = []
        if let current, let repo = repos[current] {
            names += [repo.name].compactMap { $0 } + repo.glossary + repo.skills + repo.dependencies
        }
        names += user
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }.map(Term.init)
    }
}

/// Reads code names from folders. Pure file reads, no watching (`CodeTerms` watches).
///
/// A repo is a folder directly under the code root. Manifests count at the
/// repo's root and up to two folders down (a monorepo's `packages/web`), never
/// inside hidden or build folders, so `node_modules` and vendored code add nothing.
/// GLOSSARY.md counts at the root only.
enum CodeScan {
    /// Folders below a repo's root holding manifests: two levels covers the
    /// workspaces of every monorepo layout seen (`packages/*`, `crates/*`).
    static let manifestDepth = 2
    /// Folders a tool writes, not Jake: dependencies, build output and git's own.
    /// A change inside one never makes its repo current, and their manifests are never read.
    static let derived: Set<String> = [
        ".git", ".build", "node_modules", "build", "dist", "out", "target", "vendor", "Pods", "DerivedData", "venv",
        ".venv", "__pycache__",
    ]
    /// Folders whose manifests name packages for a sample, not for the repo.
    static let samples: Set<String> = ["examples", "fixtures", "testdata"]
    /// A manifest or glossary bigger than this is not one a person wrote: skipped.
    static let largestFile = 1 << 20
    /// Where skills and slash commands live, in a repo and in the home folder:
    /// Claude Code's skills and commands, and the shared `.agents` skills Codex reads.
    static let skillFolders = [".claude/skills", ".claude/commands", ".agents/skills"]

    /// The whole index. `code` may be missing (no `~/code`): then only the home folder counts.
    static func scan(code: URL?, home: URL) -> CodeIndex {
        let found = code.map { folders(in: $0).map(allNames(ofRepo:)) } ?? []
        // One pass over the word list for every repo: it costs the same for one name as for thousands.
        let plain = PlainNames(found)
        let repos = found.map { ($0.name ?? "", plain.dropping(from: $0)) }
        return CodeIndex(repos: Dictionary(repos, uniquingKeysWith: { first, _ in first }), user: skillNames(in: home))
    }

    /// One repo's names, plain-English ones dropped.
    static func names(ofRepo url: URL) -> RepoNames {
        let found = allNames(ofRepo: url)
        return PlainNames([found]).dropping(from: found)
    }

    /// One repo's names, plain-English ones and all.
    private static func allNames(ofRepo url: URL) -> RepoNames {
        let glossary = text(of: url.appending(path: "GLOSSARY.md")).map(boldTerms(in:)) ?? []
        var dependencies: [String] = []
        for manifest in manifests(in: url, depth: 0) {
            guard let text = text(of: manifest) else { continue }
            dependencies += Manifest.dependencies(fileName: manifest.lastPathComponent, text: text)
        }
        return RepoNames(name: url.lastPathComponent, glossary: glossary, skills: skillNames(in: url),
                         dependencies: dependencies)
    }

    /// True when a change at `components` (the path below a repo's root) can
    /// change the repo's names, so the repo is read again. A folder counts where a
    /// manifest could sit inside it: renaming `packages/web` moves its manifest
    /// without an event for the file.
    static func changesNames(_ components: [Substring], folder: Bool) -> Bool {
        guard let last = components.last else { return true }  // the repo folder itself
        // The file system ignores case, so `glossary.md` is the file the scan read.
        if components.count == 1 && last.lowercased() == "glossary.md" { return true }
        let path = components.joined(separator: "/")
        for skills in skillFolders where path == skills || path.hasPrefix(skills + "/") || skills.hasPrefix(path + "/") {
            return true
        }
        let folders = folder ? components : components.dropLast()
        guard folders.count <= manifestDepth,
              !folders.contains(where: { $0.hasPrefix(".") || derived.contains(String($0)) || samples.contains(String($0)) })
        else { return false }
        return folder || Manifest.fileNames.contains(String(last))
    }

    /// "/name" for each skill (a folder holding SKILL.md) and each slash command
    /// (a `.md` file; one in `commands/team/` is "/team:name"), sorted per folder.
    static func skillNames(in base: URL) -> [String] {
        var names: [String] = []
        for folder in skillFolders {
            let url = base.appending(path: folder)
            if folder.hasSuffix("commands") {
                names += commands(in: url, prefix: "")
            } else {
                // A skill folder may be a symlink (`~/.agents/skills` links into other packs): follow it.
                names += folders(in: url, followingLinks: true)
                    .filter { FileManager.default.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
                    .map { "/" + $0.lastPathComponent }
            }
        }
        return names
    }

    /// The text inside each `**bold**` span that reads as a term: one line, at
    /// most 4 words and 40 characters. A trailing colon is dropped ("**Fix**:"),
    /// and so are stars, underscores and backticks around it ("***Fix***").
    static func boldTerms(in markdown: String) -> [String] {
        var terms: [String] = []
        for line in markdown.split(whereSeparator: \.isNewline) {
            let spans = line.components(separatedBy: "**")
            // Odd pieces sit between an opening and a closing "**".
            for index in stride(from: 1, to: spans.count - 1, by: 2) {
                var term = spans[index].trimmingCharacters(in: CharacterSet(charactersIn: " *_`"))
                if term.hasSuffix(":") { term.removeLast() }
                // Backticks or stars left inside mean the "**" pair was code or emphasis, not a term.
                guard !term.isEmpty, term.count <= 40, term.split(separator: " ").count <= 4,
                      !term.contains(where: { $0 == "`" || $0 == "*" }) else { continue }
                terms.append(term)
            }
        }
        return terms
    }

    /// True when `path` lies inside a folder a tool writes (`derived`).
    static func isDerived(_ path: String) -> Bool {
        path.split(separator: "/").contains { derived.contains(String($0)) }
    }

    private static func text(of url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= largestFile else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Visible subfolders of `url`, sorted by name.
    static func folders(in url: URL, followingLinks: Bool = false) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                     options: .skipsHiddenFiles)) ?? []
        return entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { return true }
            guard followingLinks, values?.isSymbolicLink == true else { return false }
            return (try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Manifests in `url` and its visible, non-build subfolders, root first.
    private static func manifests(in url: URL, depth: Int) -> [URL] {
        var found = Manifest.fileNames.sorted().map { url.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard depth < manifestDepth else { return found }
        for folder in folders(in: url)
        where !derived.contains(folder.lastPathComponent) && !samples.contains(folder.lastPathComponent) {
            found += manifests(in: folder, depth: depth + 1)
        }
        return found
    }

    private static func commands(in url: URL, prefix: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        var names = files.sorted().filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .map { "/" + prefix + $0.dropLast(3) }
        for folder in folders(in: url) where prefix.isEmpty {
            names += commands(in: folder, prefix: folder.lastPathComponent + ":")
        }
        return names
    }
}

/// Which code names are plain English: every run of letters is a plain-English
/// word and there is no digit ("react", "react-query", "Dictation", but not
/// "supabase-js" or "web3"). A plain-English name is never a code Term: the
/// models already write it, and handing them "react" as an exact spelling would
/// lowercase the word in Jake's prose. Slash names always stay.
struct PlainNames {
    private let english: Set<String>

    init(_ repos: [RepoNames]) {
        let names = repos.flatMap { [$0.name].compactMap { $0 } + $0.glossary + $0.dependencies }
        english = EnglishWords.among(Set(names.flatMap(Self.runs(in:))))
    }

    /// `repo` without its plain-English names. Skills and commands all stay.
    func dropping(from repo: RepoNames) -> RepoNames {
        RepoNames(name: repo.name.flatMap { keeps($0) ? $0 : nil }, glossary: repo.glossary.filter(keeps),
                  skills: repo.skills, dependencies: repo.dependencies.filter(keeps))
    }

    func keeps(_ name: String) -> Bool {
        let runs = Self.runs(in: name)
        // No letters, or a lone letter ("n"): not a name anyone says, and a lone letter would bend "and".
        guard !runs.isEmpty, name.count > 1 else { return false }
        return name.contains(where: \.isNumber) || !runs.allSatisfy(english.contains)
    }

    private static func runs(in name: String) -> [String] {
        name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}

/// Dependency names from one manifest's text, in the order written, each once.
enum Manifest {
    static let fileNames: Set<String> = ["Package.swift", "package.json", "Cargo.toml", "pyproject.toml"]

    static func dependencies(fileName: String, text: String) -> [String] {
        let names: [String]
        switch fileName {
        case "Package.swift": names = swiftPackage(text)
        case "package.json": names = packageJSON(text)
        case "Cargo.toml": names = cargo(text)
        case "pyproject.toml": names = pyproject(text)
        default: names = []
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
