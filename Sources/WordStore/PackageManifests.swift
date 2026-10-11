import Foundation

extension Manifest {
    /// The name each `.package(...)` call gives, in the order written. No Swift parser:
    /// comments go first, which keeps a commented-out call out. An argument may be a call
    /// itself, as in `.exact("1.0.0")`, so one level of parentheses is matched.
    /// `.product(package:)` never matches `.package(`.
    static func swiftPackage(_ text: String) -> [String] {
        var names: [String] = []
        // A string matches whole, so a parenthesis inside one does not end the call.
        let pattern = #"\.package\(((?:"[^"\n]*"|\((?:"[^"\n]*"|[^"()])*\)|[^"()])*)\)"#
        for call in groups(of: pattern, in: withoutComments(text)) {
            if let name = swiftPackageName(call[0]) { names.append(name) }
        }
        return names
    }

    /// The names in package.json, section by section. JSON objects keep no key
    /// order, so each section is sorted. A value never names a package: an `npm:`
    /// alias or a git URL keeps its key.
    static func packageJSON(_ text: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return []
        }
        var names: [String] = []
        for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            names += (object[section] as? [String: Any] ?? [:]).keys.sorted()
        }
        // npm also accepts `bundleDependencies: true`, which names nothing.
        let bundled = (object["bundleDependencies"] ?? object["bundledDependencies"]) as? [Any] ?? []
        names += bundled.compactMap { $0 as? String }
        // A `@types/x` package only repeats the package it types.
        return names.filter { !$0.hasPrefix("@types/") }
    }

    /// One `.package(...)` call's name: `name:` if given, else the repo at the end
    /// of `url:` or `path:`, else the part after the dot in `id:` ("scope.Name").
    private static func swiftPackageName(_ arguments: String) -> String? {
        let pairs = groups(of: #"\b(name|url|path|id):\s*"([^"]*)""#, in: arguments)
        let values = Dictionary(pairs.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        if let name = values["name"] { return name }
        if let location = values["url"] ?? values["path"] { return repoName(location) }
        return values["id"].map { String($0.split(separator: ".", maxSplits: 1).last ?? "") }
    }

    /// The last part of a URL or path with `.git` dropped: `https://host/x/Foo.git`,
    /// `git@host:x/Foo.git` and `../Foo/` all give Foo.
    private static func repoName(_ location: String) -> String {
        let last = location.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? ""
        return String(last.hasSuffix(".git") ? last.dropLast(4) : last)
    }

    /// `text` with its comments blanked. A string literal matches before a comment
    /// can start, so the `//` in a URL is not one. Multi-line strings match whole.
    private static func withoutComments(_ text: String) -> String {
        let pattern = #"("{3}[\s\S]*?"{3}|"(?:\\.|[^"\\\n])*")|//[^\n]*|/\*[\s\S]*?\*/"#
        return try! NSRegularExpression(pattern: pattern)
            .stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    /// The capture groups of each match of `pattern` in `text`, one array per match.
    private static func groups(of pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
