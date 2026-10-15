import Foundation
import Testing

private struct ImportCheckerTarget: Encodable {
    let type: String
    let name: String
    let c99name: String
    let path: String
    let sources: [String]
    let target_dependencies: [String]
    let product_dependencies: [String]
}

private struct ImportCheckerPackage: Encodable {
    let targets: [ImportCheckerTarget]
}

private struct ImportCheckerSource {
    let path: String
    let text: String
}

private struct ImportCheckerFixtureTarget {
    let type: String
    let name: String
    let c99name: String
    let path: String
    let sources: [ImportCheckerSource]
    var targetDependencies: [String] = []
    var productDependencies: [String] = []

    var description: ImportCheckerTarget {
        ImportCheckerTarget(
            type: type,
            name: name,
            c99name: c99name,
            path: path,
            sources: sources.map(\.path),
            target_dependencies: targetDependencies,
            product_dependencies: productDependencies
        )
    }
}

private struct ImportCheckerResult {
    let status: Int32
    let output: String
}

private func importCheckerResult(targets: [ImportCheckerFixtureTarget]) async throws -> ImportCheckerResult {
    let root = try scratchDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let fileManager = FileManager.default
    let fakeBin = root.appending(path: "fake-bin")
    try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)

    for target in targets {
        for source in target.sources {
            let file = root.appending(path: target.path).appending(path: source.path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try source.text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    let packageJSON = root.appending(path: "package-description.json")
    let package = ImportCheckerPackage(targets: targets.map(\.description))
    try JSONEncoder().encode(package).write(to: packageJSON)

    let fakeSwift = fakeBin.appending(path: "swift")
    let fakeSwiftBody = """
    #!/bin/sh
    if [ "$#" -eq 4 ] && [ "$1" = "package" ] && [ "$2" = "describe" ] && [ "$3" = "--type" ] && [ "$4" = "json" ]; then
      exec /bin/cat "$LEXICON_IMPORT_CHECK_FIXTURE_JSON"
    fi
    echo "unexpected swift invocation" >&2
    exit 64
    """
    try fakeSwiftBody.write(to: fakeSwift, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwift.path)

    let repository = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let checker = repository.appending(path: "scripts/check-imports.swift")
    let child = try await runChild(URL(filePath: "/usr/bin/env"), [
        "HOME=\(root.path)",
        "PATH=\(fakeBin.path):/usr/bin:/bin",
        "LEXICON_IMPORT_CHECK_FIXTURE_JSON=\(packageJSON.path)",
        "/bin/sh",
        "-c",
        "cd \"$1\" && exec /usr/bin/swift \"$2\"",
        "import-check",
        root.path,
        checker.path
    ])
    return ImportCheckerResult(status: child.status, output: child.output)
}

private func target(
    _ type: String,
    _ name: String,
    _ c99name: String,
    _ path: String,
    _ sources: ImportCheckerSource...,
    targetDependencies: [String] = [],
    productDependencies: [String] = []
) -> ImportCheckerFixtureTarget {
    ImportCheckerFixtureTarget(
        type: type,
        name: name,
        c99name: c99name,
        path: path,
        sources: sources,
        targetDependencies: targetDependencies,
        productDependencies: productDependencies
    )
}

private func source(_ path: String, importing module: String? = nil) -> ImportCheckerSource {
    ImportCheckerSource(path: path, text: module.map { "import \($0)\n" } ?? "")
}

@Suite(.serialized)
struct ImportCheckerTests {
    @Test(.timeLimit(.minutes(1)))
    func settingsWindowAppKitAllowanceAcceptsOnlyTheCanonicalTestFile() async throws {
        let result = try await importCheckerResult(targets: [
            target(
                "test", "LexiconTests", "LexiconTests", "Tests/LexiconTests",
                source("SettingsWindowTests.swift", importing: "AppKit")
            )
        ])

        #expect(result.status == 0)
        #expect(result.output.contains("check-imports: OK"))
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsWindowAppKitAllowanceRejectsLookalikesWrongTargetsAndUndeclaredDependencies() async throws {
        let result = try await importCheckerResult(targets: [
            target(
                "test", "LexiconTests", "LexiconTests", "Tests/LexiconTests",
                source("Other.swift", importing: "AppKit"),
                source("nested/SettingsWindowTests.swift", importing: "AppKit"),
                source("SettingsWindowTestsExtra.swift", importing: "AppKit"),
                source("SettingsWindowTests.swift", importing: "AppKit")
            ),
            target(
                "regular", "LexiconCore", "LexiconCore", "Tests/LexiconTests",
                source("SettingsWindowTests.swift", importing: "AppKit")
            ),
            target(
                "test", "WrongNameTests", "LexiconTests", "Tests/LexiconTests",
                source("SettingsWindowTests.swift", importing: "AppKit")
            ),
            target("regular", "OrdinaryModuleTarget", "OrdinaryModule", "Sources/OrdinaryModule", source("Module.swift")),
            target(
                "regular", "UndeclaredModuleConsumer", "UndeclaredModuleConsumer", "Sources/UndeclaredModuleConsumer",
                source("Consumer.swift", importing: "OrdinaryModule")
            ),
            target(
                "regular", "DeclaredModuleConsumer", "DeclaredModuleConsumer", "Sources/DeclaredModuleConsumer",
                source("Consumer.swift", importing: "OrdinaryModule"),
                targetDependencies: ["OrdinaryModuleTarget"]
            ),
            target(
                "regular", "ProductCatalog", "ProductCatalog", "Sources/ProductCatalog", source("Catalog.swift"),
                productDependencies: ["ExternalKit"]
            ),
            target(
                "regular", "UndeclaredProductConsumer", "UndeclaredProductConsumer", "Sources/UndeclaredProductConsumer",
                source("Consumer.swift", importing: "ExternalKit")
            ),
            target(
                "regular", "DeclaredProductConsumer", "DeclaredProductConsumer", "Sources/DeclaredProductConsumer",
                source("Consumer.swift", importing: "ExternalKit"),
                productDependencies: ["ExternalKit"]
            )
        ])

        #expect(result.status == 1)
        #expect(result.output.contains("Tests/LexiconTests/Other.swift:1: LexiconTests imports AppKit"))
        #expect(result.output.contains("Tests/LexiconTests/nested/SettingsWindowTests.swift:1: LexiconTests imports AppKit"))
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTestsExtra.swift:1: LexiconTests imports AppKit"))
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:1: LexiconCore imports AppKit"))
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:1: LexiconTests imports AppKit"))
        #expect(result.output.contains("Sources/UndeclaredModuleConsumer/Consumer.swift:1: UndeclaredModuleConsumer imports OrdinaryModule but does not depend on it directly"))
        #expect(!result.output.contains("Sources/DeclaredModuleConsumer/Consumer.swift:1:"))
        #expect(result.output.contains("Sources/UndeclaredProductConsumer/Consumer.swift:1: UndeclaredProductConsumer imports product ExternalKit"))
        #expect(!result.output.contains("Sources/DeclaredProductConsumer/Consumer.swift:1:"))
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsWindowAppKitAllowanceRejectsNoncanonicalPathAndModule() async throws {
        for (path, module) in [("prefix/Tests/LexiconTests", "LexiconTests"), ("Tests/LexiconTests", "AnotherModule")] {
            let result = try await importCheckerResult(targets: [
                target("test", "LexiconTests", module, path,
                       source("SettingsWindowTests.swift", importing: "AppKit"))
            ])
            #expect(result.status == 1)
            #expect(result.output.contains("\(path)/SettingsWindowTests.swift:1: \(module) imports AppKit"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsWindowAppKitAllowanceRequiresTheTestTargetType() async throws {
        let result = try await importCheckerResult(targets: [
            target(
                "executable", "LexiconTests", "LexiconTests", "Tests/LexiconTests",
                source("SettingsWindowTests.swift", importing: "AppKit")
            )
        ])

        #expect(result.status == 1)
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:1: LexiconTests imports AppKit"))
    }

    @Test(.timeLimit(.minutes(1)))
    func settingsWindowAllowanceDoesNotPermitCocoaSwiftUIOrCombine() async throws {
        let result = try await importCheckerResult(targets: [
            target(
                "test", "LexiconTests", "LexiconTests", "Tests/LexiconTests",
                ImportCheckerSource(
                    path: "SettingsWindowTests.swift",
                    text: "import Cocoa\nimport SwiftUI\nimport Combine\n"
                )
            )
        ])

        #expect(result.status == 1)
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:1: LexiconTests imports Cocoa"))
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:2: LexiconTests imports SwiftUI"))
        #expect(result.output.contains("Tests/LexiconTests/SettingsWindowTests.swift:3: LexiconTests imports Combine"))
    }
}
