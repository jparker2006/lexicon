import Foundation

/// Compiles `source` against the AudioCapture module this test run built, as
/// far as SIL: ownership ("consumed more than once") is checked there, after type checking.
/// `runChild` blocks no thread while swiftc runs: blocking a cooperative-pool
/// thread for its 6 to 10 s starves the realtime audio tests on a 3-core runner.
public func compile(_ source: String) async throws -> (status: Int32, output: String) {
    var image = Dl_info()
    guard dladdr(#dsohandle, &image) != 0 else { throw CompileError("cannot find the test binary") }
    var bundle = URL(filePath: String(cString: image.dli_fname))
    while bundle.pathExtension != "xctest" {
        guard bundle.pathComponents.count > 1 else { throw CompileError("the test binary is not inside an .xctest bundle") }
        bundle.deleteLastPathComponent()
    }
    let modules = bundle.deletingLastPathComponent().appending(path: "Modules")
    let file = try scratchDirectory().appending(path: "snippet.swift")
    try ("import AudioCapture\n" + source).write(to: file, atomically: true, encoding: .utf8)
    #if arch(arm64)
    let target = "arm64-apple-macos26.0"
    #else
    let target = "x86_64-apple-macos26.0"
    #endif
    return try await runChild(URL(filePath: "/usr/bin/xcrun"), [
        "swiftc", "-emit-sil", "-o", "/dev/null", "-swift-version", "6", "-target", target, "-I", modules.path, file.path,
    ])
}

struct CompileError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
