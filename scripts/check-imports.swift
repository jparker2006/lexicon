// check-imports: every import a target writes must be declared DIRECTLY in Package.swift.
//
//   swift scripts/check-imports.swift          (from the package root; CI runs it)
//
// Why: `swift build --explicit-target-dependency-import-check error` rejects an
// import of a package module outside a target's dependency closure, but not a
// TRANSITIVE one (LexiconCore -> History -> SQLiteKit lets LexiconCore write
// `import SQLiteKit`). This script derives the rule from `swift package describe`,
// so there is no hand-maintained table of package targets to drift.
//
// The only hand list is SOLE_OWNERS below: system modules that one or a few
// modules own by design. A module mapped to [] is banned everywhere.
//
// Exit 0: clean. Exit 1: one line per violation. Exit 2: could not run.

import Foundation

let soleOwners: [String: Set<String>] = [
    "SQLite3": ["SQLiteKit"],
    "FluidAudio": ["LocalParakeet"],
    "AppKit": ["AppText", "LexiconUI", "LexiconApp"],
    "Cocoa": ["AppText", "LexiconUI", "LexiconApp"],  // re-exports AppKit
    "ApplicationServices": ["AppText"],
    "FoundationModels": ["Cleanup"],
    "SwiftUI": [],  // AppKit only (Jake's decision)
    "Combine": [],
]

struct Package: Decodable {
    struct Target: Decodable {
        let name: String
        let c99name: String
        let path: String
        let sources: [String]
        let target_dependencies: [String]?
        let product_dependencies: [String]?
    }
    let targets: [Target]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("check-imports: \(message)\n".utf8))
    exit(2)
}

func describePackage() -> Package {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = ["swift", "package", "describe", "--type", "json"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.standardError
    do { try process.run() } catch { fail("cannot run swift package describe: \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("swift package describe exited \(process.terminationStatus)") }
    do { return try JSONDecoder().decode(Package.self, from: data) } catch { fail("unexpected describe JSON: \(error)") }
}

// `import X`, `import X.Y`, `import struct X.Y`, with any attributes
// (`@preconcurrency`, `@_exported`, `@testable`, `@_spi(S)`, `@_implementationOnly`)
// and any access level (`public import`, `internal import`, ...).
let importLine = #/^\s*(?:@[A-Za-z_]+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|open)\s+)?import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func|actor)\s+)?([A-Za-z_][A-Za-z0-9_]*)/#

let package = describePackage()
let moduleOfTarget = Dictionary(uniqueKeysWithValues: package.targets.map { ($0.name, $0.c99name) })
let packageModules = Set(moduleOfTarget.values)
let allProducts = Set(package.targets.flatMap { $0.product_dependencies ?? [] })

var violations: [String] = []
for target in package.targets.sorted(by: { $0.name < $1.name }) {
    let module = target.c99name
    let declaredTargets = Set((target.target_dependencies ?? []).map { moduleOfTarget[$0] ?? $0 })
    let declaredProducts = Set(target.product_dependencies ?? [])
    for source in target.sources where source.hasSuffix(".swift") {
        let file = target.path + "/" + source
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("cannot read \(file)") }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let match = line.firstMatch(of: importLine) else { continue }
            let imported = String(match.1)
            let at = "\(file):\(index + 1)"
            if let owners = soleOwners[imported], !owners.contains(module) {
                let allowed = owners.isEmpty ? "no module may import it" : "only \(owners.sorted().joined(separator: ", ")) may"
                violations.append("\(at): \(module) imports \(imported); \(allowed)")
            } else if packageModules.contains(imported), imported != module, !declaredTargets.contains(imported) {
                violations.append("\(at): \(module) imports \(imported) but does not depend on it directly in Package.swift")
            } else if allProducts.contains(imported), !declaredProducts.contains(imported) {
                violations.append("\(at): \(module) imports product \(imported) but does not declare it in Package.swift")
            }
        }
    }
}

if violations.isEmpty {
    print("check-imports: OK (\(package.targets.count) targets)")
    exit(0)
}
violations.forEach { print($0) }
print("check-imports: \(violations.count) violation(s)")
exit(1)
