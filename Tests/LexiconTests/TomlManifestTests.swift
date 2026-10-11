import Testing
@testable import WordStore

// The dependency names read from Cargo.toml and pyproject.toml, through
// Manifest.dependencies. Every fixture is written here, with made-up names only.

private func cargoNames(_ text: String) -> [String] {
    Manifest.dependencies(fileName: "Cargo.toml", text: text)
}

private func pyprojectNames(_ text: String) -> [String] {
    Manifest.dependencies(fileName: "pyproject.toml", text: text)
}

struct TomlManifestTests {
    @Test func cargoDependencyTablesOfEveryKind() {
        let text = #"""
            [package]
            name = "zorblax"
            version = "0.1.0"

            [dependencies]
            alpha = "1"
            beta = { version = "2", features = ["x"] }
            gamma.workspace = true

            [dev-dependencies]
            delta = "3"

            [build-dependencies]
            epsilon = "4"

            [workspace.dependencies]
            zeta = "5"
            """#
        #expect(cargoNames(text) == ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"])
    }

    @Test func cargoTargetTablesReadLikeThePlainOnes() {
        let text = #"""
            [target.'cfg(unix)'.dependencies]
            eta = "1"

            [target."x86_64-pc-windows-gnu".dev-dependencies]
            theta = "1"

            [target.'cfg(target_os = "macos")'.build-dependencies]
            iota = "1"

            [target.'cfg(unix)'.dependencies.kappa]
            version = "1"

            [target.'cfg(unix)'.lints.clippy]
            pedantic = "warn"
            """#
        #expect(cargoNames(text) == ["eta", "theta", "iota", "kappa"])
    }

    @Test func cargoCrateTablesNameTheCrate() {
        let text = #"""
            [dependencies.lambda]
            version = "1"
            features = [
              "a",
            ]

            [dev-dependencies.mu]
            version = "2"

            [build-dependencies.nu]
            version = "3"

            [workspace.dependencies.xi]
            path = "../xi"
            """#
        #expect(cargoNames(text) == ["lambda", "mu", "nu", "xi"])
    }

    @Test func cargoRenamesGiveThePackageName() {
        let text = #"""
            [dependencies]
            alias-one = { package = "real-one", version = "1" }
            alias-two.package = "real-two"
            alias-three = { version = "1", features = ["x"],
              package = "real-three" }

            [dependencies.alias-four]
            package = "real-four"
            version = "1"
            """#
        #expect(cargoNames(text) == ["real-one", "real-two", "real-three", "real-four"])
    }

    @Test func cargoSingleQuotedRenamesKeepTheRealNameAsWritten() {
        let text = #"""
            [dependencies]
            alias-five = { version = "1", package = 'real_five' }
            alias-six.package = 'real_six'

            [dev-dependencies.alias-seven]
            package = 'real_seven'
            """#
        #expect(cargoNames(text) == ["real_five", "real_six", "real_seven"])
    }

    @Test func cargoMultiLineValuesGiveNoInnerNames() {
        let text = #"""
            [dependencies]
            omega = { version = "1",
              features = [
                "a = b",
                "c" ] }
            psi = { version = "2",
              sigma = "9" }
            chi = { version = "3",
              package = "real-chi" }
            pi = "3"
            """#
        #expect(cargoNames(text) == ["omega", "psi", "real-chi", "pi"])
    }

    @Test func cargoNeverNamesAnyOtherTable() {
        let text = #"""
            [package]
            name = "zorblax"
            version = "0.1.0"

            [workspace]
            members = ["crates/alpha"]

            [features]
            default = ["flimflam-rs"]

            [patch.crates-io]
            omega = { path = "../omega" }

            [replace]
            "psi:1.0.0" = { path = "../psi" }

            [profile.dev.package.omega]
            opt-level = 1

            [lib]
            name = "zorblax_lib"

            [dependencies]
            alpha = "1"

            [[bin]]
            name = "zorblax-cli"
            beta = "2"

            [[dependencies]]
            chi = "1"
            """#
        #expect(cargoNames(text) == ["alpha"])
    }

    @Test func cargoCommentsAndQuotedKeys() {
        let text = #"""
            # [dependencies] is only a comment here
            [dependencies] # trailing comment
            "quoted-crate" = "1" # a comment with = and "quotes
            'single-quoted' = { version = "1" } # x
            hash-in-string = "a#b"
            """#
        #expect(cargoNames(text) == ["quoted-crate", "single-quoted", "hash-in-string"])
    }

    @Test func cargoTripleQuotedBodiesHoldNoHeadersOrKeys() {
        let text = #"""
            [package]
            description = """
            [dependencies]
            ghost = "1"
            """
            notes = '''
            [dev-dependencies]
            phantom = "1"
            '''

            [dependencies]
            real-crate = "1"
            """#
        #expect(cargoNames(text) == ["real-crate"])
    }

    @Test func pyprojectProjectDependenciesOnOneLine() {
        let text = #"""
            [build-system]
            requires = ["setuptools>=61", "wheel"]

            [project]
            name = "zorblax"
            dependencies = ["flimflam-rs>=1.2", "quux"]

            [tool.other]
            dependencies = ["ignored"]
            """#
        #expect(pyprojectNames(text) == ["flimflam-rs", "quux"])
    }

    @Test func pyprojectRequirementsKeepTheirNames() {
        let text = #"""
            [project]
            name = "zorblax"
            dependencies = [
                "fastapi[standard]>=0.1",  # a comment with ] and [
                'pandas ; python_version<"3.9"',
                "foo @ git+https://example.com/foo.git",
                "bar~=2.0 ; sys_platform == 'linux'",
                "baz (>=1.0)",
                "qux!=1",
                "quux==1; extra == 'x'",
                "ni-ce_name.x>=1",
                "Mixed_Case.Name>=1",
            ]
            """#
        #expect(pyprojectNames(text) == [
            "fastapi", "pandas", "foo", "bar", "baz", "qux", "quux", "ni-ce_name.x", "Mixed_Case.Name",
        ])
    }

    @Test func pyprojectOptionalAndGroupDependencies() {
        let text = #"""
            [project.optional-dependencies]
            cron = ["croniter>=1"]
            web = [
              "uvicorn",
            ]

            [dependency-groups]
            dev = ["pytest", { include-group = "lint" }]
            lint = ["ruff"]

            [tool.pdm.dev-dependencies]
            test = ["hypothesis"]
            """#
        #expect(pyprojectNames(text) == ["croniter", "uvicorn", "pytest", "ruff", "hypothesis"])
    }

    @Test func pyprojectUvDevDependencies() {
        let text = #"""
            [tool.uv]
            dev-dependencies = ["pytest-cov", "mypy"]
            managed = true

            [tool.uv.sources]
            flimflam-rs = { git = "https://example.com/flimflam-rs" }
            """#
        #expect(pyprojectNames(text) == ["pytest-cov", "mypy"])
    }

    @Test func poetryDependenciesSkipPython() {
        let text = #"""
            [tool.poetry]
            name = "zorblax"

            [tool.poetry.dependencies]
            python = "^3.11"
            requests = { version = "2.31", extras = [
              "socks",
            ] }
            tqdm = "4"

            [tool.poetry.dev-dependencies]
            black = "24"

            [tool.poetry.group.docs.dependencies]
            sphinx = "7"
            """#
        #expect(pyprojectNames(text) == ["requests", "tqdm", "black", "sphinx"])
    }

    @Test func pyprojectOwnNameAndBuildToolsAreNotDependencies() {
        let text = #"""
            [build-system]
            requires = ["setuptools>=61", "wheel"]

            [project]
            name = "flimflam-rs"
            dependencies = [
                "Flimflam_RS[cron]>=1",
                "flimflam-rs-extra",
            ]

            [project.optional-dependencies]
            all = ["flimflam_rs[cron]"]
            """#
        #expect(pyprojectNames(text) == ["flimflam-rs-extra"])
    }

    @Test func pyprojectTripleQuotedBodiesHoldNoHeadersOrKeys() {
        let text = #"""
            [project]
            name = "zorblax"
            description = """
            dependencies = ["ghost"]
            [dependency-groups]
            dev = ["phantom"]
            """
            notes = '''
            [project]
            dependencies = ["spectre"]
            '''
            dependencies = ["real-one"]
            """#
        #expect(pyprojectNames(text) == ["real-one"])
    }
}
