import Foundation

extension Manifest {
    /// Crate names in Cargo.toml, in the order written: every key of a dependency table
    /// (under any `[target.<cfg>]`), each `[dependencies.foo]` table, and a renamed crate
    /// under its package name, the crate Jake depends on, not the local alias.
    static func cargo(_ text: String) -> [String] {
        var names: [String] = []
        for table in Toml.tables(in: text) {
            guard let path = table.path else { continue }  // `[[array]]` tables are never dependencies
            let rest = cargoPathWithoutTarget(path)
            if rest == ["workspace", "dependencies"] || (rest.count == 1 && cargoDependencyKeys.contains(rest[0])) {
                names += table.pairs.map(cargoCrateName)
            } else if let crate = cargoCrateTable(rest) {
                // A crate's own table renames it with a `package` key, as an inline table does.
                let real = table.pairs.first { $0.key == ["package"] }.flatMap { Toml.quoted($0.value) }
                names.append(real ?? crate)
            }
        }
        return names
    }

    /// PEP 508 names in pyproject.toml, in the order written: the project's dependencies,
    /// its optional and dependency groups, uv's and PDM's dev dependencies, and Poetry's.
    /// `[build-system]` names build tools, and a project never depends on itself, so its
    /// own name is dropped even when a requirement adds extras to it.
    static func pyproject(_ text: String) -> [String] {
        let tables = Toml.tables(in: text)
        let own = tables.filter { $0.path == ["project"] }.flatMap { $0.pairs }
            .first { $0.key == ["name"] }.flatMap { Toml.quoted($0.value) }.map(pep503)
        var names: [String] = []
        for table in tables {
            guard let path = table.path else { continue }
            if path == ["project"] {
                for pair in table.pairs where pair.key == ["dependencies"] {
                    names += pyprojectRequirements(pair.value)
                }
            } else if pyprojectRequirementTables.contains(path) {
                for pair in table.pairs { names += pyprojectRequirements(pair.value) }
            } else if path == ["tool", "uv"] {
                for pair in table.pairs where pair.key == ["dev-dependencies"] {
                    names += pyprojectRequirements(pair.value)
                }
            } else if isPoetryDependencies(path) {
                // Poetry's keys are the names themselves; `python` is the interpreter, not a package.
                for pair in table.pairs where pair.key != ["python"] { names.append(pair.key[0]) }
            } else if let package = poetryPackageTable(path), package != "python" {
                // A table per package names it in its header; body keys such as `version` name nothing.
                names.append(package)
            }
        }
        return names.filter { own == nil || pep503($0) != own }
    }

    /// The keys of Cargo's dependency tables.
    private static let cargoDependencyKeys: Set<String> = ["dependencies", "dev-dependencies", "build-dependencies"]

    /// Tables whose every key holds an array of requirement strings.
    private static let pyprojectRequirementTables: [[String]] = [
        ["project", "optional-dependencies"], ["dependency-groups"], ["tool", "pdm", "dev-dependencies"],
    ]

    /// The crate a line of a dependency table names: its `package` rename, else its key.
    private static func cargoCrateName(_ pair: Toml.Pair) -> String {
        if pair.key.count == 2, pair.key[1] == "package", let real = Toml.quoted(pair.value) { return real }
        return Toml.entry("package", in: pair.value) ?? pair.key[0]
    }

    /// The crate a `[dependencies.foo]` or `[workspace.dependencies.foo]` table is for.
    private static func cargoCrateTable(_ rest: [String]) -> String? {
        if rest.count == 2 && cargoDependencyKeys.contains(rest[0]) { return rest[1] }
        if rest.count == 3 && rest[0] == "workspace" && rest[1] == "dependencies" { return rest[2] }
        return nil
    }

    /// The path with its `target.<cfg>` prefix removed, so cfg tables read like the plain ones.
    private static func cargoPathWithoutTarget(_ path: [String]) -> [String] {
        path.count >= 2 && path[0] == "target" ? Array(path.dropFirst(2)) : path
    }

    /// The names in an array of PEP 508 strings, in order. An inline table such as
    /// `{ include-group = "lint" }` names nothing.
    private static func pyprojectRequirements(_ value: String) -> [String] {
        Toml.items(value).compactMap { item in
            guard let requirement = Toml.quoted(item) else { return nil }
            return pep508Name(requirement)
        }
    }

    /// The project name at the front of a requirement: `glorp-api[standard]>=0.1` is `glorp-api`.
    /// The name stops at extras, specifiers, markers, `@` and spaces, and keeps its spelling.
    /// A URL or path has no name to read, so it gives nothing: `git+https://...` would give `git`.
    private static func pep508Name(_ requirement: String) -> String {
        let text = requirement.trimmingCharacters(in: .whitespaces)
        let name = text.prefix { character in
            (character.isASCII && (character.isLetter || character.isNumber)) || ".-_".contains(character)
        }
        guard let first = name.first, first.isLetter || first.isNumber else { return "" }
        // The name is followed by the end, or by the start of extras, a specifier, a marker or `@`.
        let next = text.dropFirst(name.count).first { !$0.isWhitespace }
        if let next, !"[<>=!~;@(,".contains(next) { return "" }
        return String(name)
    }

    /// `[tool.poetry.dependencies]`, its dev table, and `[tool.poetry.group.<name>.dependencies]`.
    private static func isPoetryDependencies(_ path: [String]) -> Bool {
        path == ["tool", "poetry", "dependencies"] || path == ["tool", "poetry", "dev-dependencies"]
            || (path.count == 5 && path.starts(with: ["tool", "poetry", "group"]) && path[4] == "dependencies")
    }

    /// The package a per-package Poetry table names: `[tool.poetry.dependencies.foo]`, its dev
    /// table, or `[tool.poetry.group.<name>.dependencies.foo]`. Nil for any other table.
    private static func poetryPackageTable(_ path: [String]) -> String? {
        let direct = path.count == 4 && path.starts(with: ["tool", "poetry"])
            && (path[2] == "dependencies" || path[2] == "dev-dependencies")
        if direct { return path[3] }
        if path.count == 6 && path.starts(with: ["tool", "poetry", "group"]) && path[4] == "dependencies" {
            return path[5]
        }
        return nil
    }

    /// PEP 503 spelling, so that comparing names ignores case and reads `_` and `.` as `-`.
    private static func pep503(_ name: String) -> String {
        String(name.lowercased().map { $0 == "_" || $0 == "." ? "-" : $0 })
    }
}

/// A small reader for the TOML shapes the manifests use: table headers, dotted and quoted
/// keys, and values that run over several lines. It is not a TOML parser. It skips comments
/// and the bodies of triple-quoted strings, so a `[table]` or key written inside one is never read.
private enum Toml {
    struct Table {
        /// The header's path, nil under a `[[array]]` header.
        var path: [String]?
        var pairs: [Pair] = []
    }

    struct Pair {
        /// The dotted parts of the key: `foo.workspace = true` is ["foo", "workspace"].
        let key: [String]
        /// The value on its logical line, comments removed.
        let value: String
    }

    /// Every table in order. Keys before the first header belong to a root table whose path is [].
    static func tables(in text: String) -> [Table] {
        var tables = [Table(path: [])]
        for line in logicalLines(text) {
            if line.hasPrefix("[[") {
                tables.append(Table(path: nil))
            } else if line.hasPrefix("["), line.hasSuffix("]") {
                tables.append(Table(path: keyPath(String(line.dropFirst().dropLast()))))
            } else {
                let parts = splitTopLevel(line, "=")
                guard parts.count >= 2 else { continue }
                let value = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
                tables[tables.count - 1].pairs.append(Pair(key: keyPath(parts[0]), value: value))
            }
        }
        return tables
    }

    /// The text of a single-line string with its quotes removed; nil for any other value.
    static func quoted(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces)
        guard let quote = text.first, quote == "\"" || quote == "'", text.count >= 2, text.last == quote else {
            return nil
        }
        return String(text.dropFirst().dropLast())
    }

    /// The items of an array or inline table, trimmed. Any other value has none.
    static func items(_ value: String) -> [String] {
        guard let first = value.first, let last = value.last,
              (first == "[" && last == "]") || (first == "{" && last == "}") else { return [] }
        return splitTopLevel(String(value.dropFirst().dropLast()), ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The string that an inline table's `key = "..."` entry holds, such as the package in
    /// `{ version = "1", package = "real" }`. Nil when there is no such entry.
    static func entry(_ key: String, in value: String) -> String? {
        for item in items(value) {
            let parts = splitTopLevel(item, "=")
            if parts.count == 2, keyPath(parts[0]) == [key], let text = quoted(parts[1]) { return text }
        }
        return nil
    }

    /// The parts of a dotted key or table name, quotes removed: `"a.b".c` is ["a.b", "c"].
    static func keyPath(_ text: String) -> [String] {
        splitTopLevel(text, ".").map { quoted($0) ?? $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `text` cut at each `separator` that sits outside quotes and brackets.
    static func splitTopLevel(_ text: String, _ separator: Character) -> [String] {
        var parts: [String] = []
        var part = ""
        var nesting = Nesting()
        for ch in text {
            if ch == separator && nesting.isTop {
                parts.append(part)
                part = ""
            } else {
                part.append(ch)
            }
            nesting.feed(ch)
        }
        parts.append(part)
        return parts
    }

    /// The logical lines. A comment is dropped, and a triple-quoted string's body is dropped
    /// too (`""` stands in for the string). A value that runs over several lines is joined
    /// onto the line it starts on, so its inner lines can never read as keys or headers.
    private static func logicalLines(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        var depth = 0  // open `[` and `{` on the logical line
        var closing: Character?  // the quote of a triple-quoted string that is still open
        for physical in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let chars = Array(physical)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if let quote = closing {
                    guard let end = tripleEnd(quote, in: chars, from: i) else { break }
                    closing = nil
                    i = end
                    continue
                }
                switch ch {
                case "#":
                    i = chars.count
                case "\"", "'":
                    if i + 2 < chars.count, chars[i + 1] == ch, chars[i + 2] == ch {
                        line += "\"\""
                        closing = ch
                        i += 3
                    } else {
                        let end = singleEnd(ch, in: chars, from: i)
                        line += String(chars[i..<end])
                        i = end
                    }
                case "[", "{":
                    depth += 1
                    line.append(ch)
                    i += 1
                case "]", "}":
                    depth = max(depth - 1, 0)
                    line.append(ch)
                    i += 1
                default:
                    line.append(ch)
                    i += 1
                }
            }
            guard closing == nil else { continue }
            if depth == 0 {
                lines.append(line)
                line = ""
            } else {
                line += " "
            }
        }
        lines.append(line)
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The index just past the single-line string that opens at `start`. A string the line
    /// leaves open ends with the line, so a broken value cannot swallow the lines after it.
    private static func singleEnd(_ quote: Character, in chars: [Character], from start: Int) -> Int {
        var i = start + 1
        while i < chars.count, chars[i] != quote {
            i += quote == "\"" && chars[i] == "\\" ? 2 : 1
        }
        return min(i + 1, chars.count)
    }

    /// The index just past the `"""` or `'''` that closes a multi-line string, or nil when the line ends first.
    private static func tripleEnd(_ quote: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 2 < chars.count {
            if quote == "\"" && chars[i] == "\\" {
                i += 2
            } else if chars[i] == quote && chars[i + 1] == quote && chars[i + 2] == quote {
                return i + 3
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Follows quotes and brackets one character at a time, so a separator counts only
    /// where it sits outside both.
    private struct Nesting {
        private var depth = 0
        private var quote: Character?
        private var escaped = false

        /// True outside every string and bracket.
        var isTop: Bool { quote == nil && depth == 0 }

        mutating func feed(_ ch: Character) {
            if let open = quote {
                if escaped {
                    escaped = false
                } else if open == "\"" && ch == "\\" {
                    escaped = true
                } else if ch == open {
                    quote = nil
                }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "[" || ch == "{" {
                depth += 1
            } else if ch == "]" || ch == "}" {
                depth = max(depth - 1, 0)
            }
        }
    }
}
