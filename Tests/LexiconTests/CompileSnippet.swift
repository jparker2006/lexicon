import Foundation
import Testing

/// Compiles `source` against the modules this test run built, as far as SIL:
/// access control is checked in type checking, ownership ("consumed more than
/// once") after it.
///
/// Waits for swiftc by its termination handler and collects output in a file,
/// so no cooperative-pool thread blocks for the seconds a compile takes. A
/// blocked pool starves every other test's awaits on a small CI runner.
func compileSnippet(_ source: String, importing modules: [String]) async throws -> (status: Int32, output: String) {
    var image = Dl_info()
    try #require(dladdr(#dsohandle, &image) != 0)
    var bundle = URL(filePath: String(cString: image.dli_fname))
    while bundle.pathExtension != "xctest" {
        try #require(bundle.pathComponents.count > 1, "test binary is not inside an .xctest bundle")
        bundle.deleteLastPathComponent()
    }
    let built = bundle.deletingLastPathComponent().appending(path: "Modules")
    let dir = try scratchDirectory()
    let file = dir.appending(path: "snippet.swift")
    let log = dir.appending(path: "swiftc.log")
    try (modules.map { "import \($0)\n" }.joined() + source).write(to: file, atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    #if arch(arm64)
    let target = "arm64-apple-macos26.0"
    #else
    let target = "x86_64-apple-macos26.0"
    #endif
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-emit-sil", "-o", "/dev/null", "-swift-version", "6", "-target", target,
                         "-I", built.path, file.path]
    let output = try FileHandle(forWritingTo: log)
    process.standardOutput = output
    process.standardError = output
    let status: Int32 = try await withCheckedThrowingContinuation { done in
        process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            done.resume(throwing: error)
        }
    }
    try output.close()
    return (status, try String(contentsOf: log, encoding: .utf8))
}
