import Testing
@testable import WordStore

// The package names a manifest gives, read through `Manifest.dependencies`, the seam
// CodeScan calls. Made-up package names in inline fixtures only.

@Test func swiftPackageURLsGiveTheRepoName() {
    let text = """
        // swift-tools-version: 6.2
        let package = Package(
            name: "Glimmer",
            dependencies: [
                .package(url: "https://github.com/Zorblax/Quux-kit", exact: "1.0.0"),
                .package(url: "https://github.com/flimflam/Snarl.git", from: "2.0.0"),
                .package(url: "git@github.com:Zorblax/Gnarl.git", from: "3.0.0"),
                .package(url: "https://github.com/flimflam/Wobble.swift.git", from: "4.0.0"),
                .package(url: "https://github.com/Zorblax/Trailing/", branch: "main"),
            ]
        )
        """
    #expect(Manifest.dependencies(fileName: "Package.swift", text: text)
        == ["Quux-kit", "Snarl", "Gnarl", "Wobble.swift", "Trailing"])
}

@Test func swiftPackageNameFormsAndTheirOrder() {
    let text = """
        let package = Package(
            name: "Glimmer",
            dependencies: [
                .package(name: "Frobnitz", url: "https://github.com/Zorblax/Ignored", from: "1.0.0"),
                .package(path: "../LocalThing"),
                .package(id: "scope.Gremlin", from: "1.0.0"),
            ]
        )
        """
    #expect(Manifest.dependencies(fileName: "Package.swift", text: text) == ["Frobnitz", "LocalThing", "Gremlin"])
}

@Test func swiftPackageNestedCallsGiveTheirName() {
    let text = """
        let package = Package(
            name: "Glimmer",
            dependencies: [
                .package(url: "https://github.com/Zorblax/Plimber.git", .upToNextMajor(from: "2.0.0")),
                .package(url: "https://github.com/flimflam/Grommet.git", .exact("1.0.0")),
                .package(url: "https://github.com/Zorblax/Dingle.git", .branch("main")),
                .package(url: "https://github.com/flimflam/Brattle.git", .revision("abc")),
                .package(url: "https://github.com/Zorblax/Smorgle.git", "1.0.0"..<"2.0.0"),
            ]
        )
        """
    #expect(Manifest.dependencies(fileName: "Package.swift", text: text)
        == ["Plimber", "Grommet", "Dingle", "Brattle", "Smorgle"])
}

@Test func swiftPackageMultiLineCallsCountAndCommentsDoNot() {
    let text = """
        let package = Package(
            name: "Glimmer",
            dependencies: [
                // .package(url: "https://github.com/Zorblax/Commented", from: "1.0.0"),
                /* .package(url: "https://github.com/Zorblax/Blocked", from: "1.0.0"), */
                .package(
                    url: "https://github.com/flimflam/Spanning",
                    from: "1.0.0"
                ),
                .package(url: "https://github.com/Zorblax/Kept", from: "1.0.0"), // .package(path: "../Trailing")
            ]
        )
        """
    #expect(Manifest.dependencies(fileName: "Package.swift", text: text) == ["Spanning", "Kept"])
}

@Test func swiftPackageLeavesOutProductsTargetsAndTheOwnName() {
    let text = """
        let package = Package(
            name: "Glimmer",
            products: [
                .library(name: "GlimmerKit", targets: ["GlimmerKit"]),
            ],
            dependencies: [
                .package(url: "https://github.com/flimflam/Spanning", from: "1.0.0"),
            ],
            targets: [
                .target(name: "Gremlin", dependencies: [.product(name: "Gnarlet", package: "Spanning")]),
                .binaryTarget(name: "Blob", url: "https://example.com/Blob.zip", checksum: "abc"),
                .testTarget(name: "GlimmerTests", dependencies: ["Gremlin"]),
            ]
        )
        """
    #expect(Manifest.dependencies(fileName: "Package.swift", text: text) == ["Spanning"])
}

@Test func packageJSONNamesEachDependencySectionSorted() {
    let text = """
        {
          "name": "glimmer-web",
          "dependencies": { "zorblax-ui": "^1.2.0", "@flimco/flim-js": "^2.0.0", "alpha-tool": "1.0.0" },
          "devDependencies": { "@types/glorp": "^20.0.0", "flimflam-kit": "^3.0.0" },
          "peerDependencies": { "snarl-peer": "*" },
          "optionalDependencies": { "zorb-lite": "^1.0.0" },
          "bundleDependencies": ["bundled-bits", 7]
        }
        """
    #expect(Manifest.dependencies(fileName: "package.json", text: text) == [
        "@flimco/flim-js", "alpha-tool", "zorblax-ui",
        "flimflam-kit", "snarl-peer", "zorb-lite", "bundled-bits",
    ])
}

@Test func packageJSONValuesNeverNameAPackage() {
    let text = """
        {
          "name": "glimmer-web",
          "version": "1.0.0",
          "scripts": { "build-all": "zorb-check && glorp build" },
          "bin": { "glimmer-cli": "./bin/cli.js" },
          "workspaces": ["packages/zorblax-core"],
          "dependencies": {
            "fast-alias": "npm:real-pkg@^1.0.0",
            "git-dep": "github:owner/repo#main",
            "local-ws": "workspace:*"
          },
          "bundledDependencies": ["stowed-bits"]
        }
        """
    #expect(Manifest.dependencies(fileName: "package.json", text: text)
        == ["fast-alias", "git-dep", "local-ws", "stowed-bits"])
}

@Test func packageJSONThatDoesNotParseGivesNoNames() {
    let text = #"{ "dependencies": { "zorblax-ui": "^1.0.0" }"#
    #expect(Manifest.dependencies(fileName: "package.json", text: text) == [])
}
