import Foundation
import Synchronization
import LexiconDomain
import LexiconCore
import LocalParakeet

// `lexicon-eval`: dev tool, never shipped. Runs the real Conductor headless on a
// WAV, at the speed of speech, and prints one JSON line:
//
//   swift run lexicon-eval <wav> [--scripted <text>]
//       {"status": "inserted", "text": "...", "lag_ms": 42}
//   swift run lexicon-eval --install-model <data folder>
//
// `lag_ms` is end of audio to text typed (the recording destination's "paste").
// `--scripted` stands in a fake engine that hears <text>, to check the pipeline
// on a Mac with no model. Without it local Parakeet runs from Lexicon Dev's
// `models/` (a symlink to the daily copy's once that is installed); with no
// model there the Dictation waits and prints no text.
// `--install-model` downloads the model into `<data folder>/models/`
// (`scripts/install-model.sh` runs it until onboarding exists).
//
// Keys come from LEXICON_KEY_* environment variables (Secrets(.environment)).
// History and audio go to a temporary folder that is deleted on exit, never to
// an app's data folder.

struct Line: Encodable {
    let status: String
    let text: String?
    let lag_ms: Int?
}

func runEval(arguments: [String]) async -> Int32 {
    var rest = arguments.dropFirst()
    if rest.first == "--install-model" {
        guard rest.count == 2, let folder = rest.last else { return usage() }
        return await installModel(into: URL(filePath: folder, directoryHint: .isDirectory))
    }
    var scripted: String?
    if let flag = rest.firstIndex(of: "--scripted") {
        guard rest.index(after: flag) < rest.endIndex else { return usage() }
        scripted = rest[rest.index(after: flag)]
        rest.removeSubrange(flag...rest.index(after: flag))
    }
    guard rest.count == 1, let path = rest.first else { return usage() }

    let paths = AppPaths.temporary()
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let system: HeadlessSystem
    do {
        system = try HeadlessSystem.make(paths: paths, context: .unknown, preferences: .defaults,
                                         local: scripted.map(ScriptedTranscriber.init(text:))
                                             ?? ParakeetTranscriber(paths: .forBundle(id: AppPaths.devBundleID)))
    } catch {
        FileHandle.standardError.write(Data("lexicon-eval: \(error)\n".utf8))
        return 1
    }
    let result = await system.conductor.dictate(file: URL(filePath: path), pace: .realtime)
    await system.history.flush()

    let line = Line(status: result.status?.rawValue ?? "nothing", text: result.versions?.cleaned,
                    lag_ms: result.lag.map { Int($0 / .milliseconds(1)) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: (try? encoder.encode(line)) ?? Data(), as: UTF8.self))
    return result.status == nil ? 1 : 0
}

func installModel(into folder: URL) async -> Int32 {
    guard let access = CloudAccess.granted(by: .defaults, app: .unknown, keys: { _ in nil }) else { return 1 }
    do {
        let shown = Mutex(-1)
        try await ParakeetTranscriber.install(paths: AppPaths(root: folder), access: access) { fraction in
            let percent = Int(fraction * 100)
            let changed = shown.withLock { last in
                defer { last = percent }
                return last != percent
            }
            guard changed else { return }
            FileHandle.standardError.write(Data("\rinstalling: \(percent)%".utf8))
        }
        FileHandle.standardError.write(Data("\ninstalled\n".utf8))
        return 0
    } catch {
        FileHandle.standardError.write(Data("\nlexicon-eval: install failed: \(error)\n".utf8))
        return 1
    }
}

func usage() -> Int32 {
    FileHandle.standardError.write(Data("usage: lexicon-eval <wav> [--scripted <text>] | --install-model <data folder>\n".utf8))
    return 2
}

exit(await runEval(arguments: CommandLine.arguments))
