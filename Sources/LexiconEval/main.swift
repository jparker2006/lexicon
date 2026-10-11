import Foundation
import LexiconDomain
import LexiconCore

// `lexicon-eval`: dev tool, never shipped. Runs the real Conductor headless on a
// WAV, at the speed of speech, and prints one JSON line:
//
//   swift run lexicon-eval <wav> [--scripted <text>]
//       {"status": "inserted", "text": "...", "lag_ms": 42}
//
// `lag_ms` is end of audio to text typed (the recording destination's "paste").
// `--scripted` stands in a fake engine that hears <text>, to check the pipeline
// on a Mac with no model. Without it the local model runs; until it is wired
// in (#47) there is none, so the Dictation waits and prints no text.
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
                                         local: scripted.map(ScriptedTranscriber.init(text:)))
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

func usage() -> Int32 {
    FileHandle.standardError.write(Data("usage: lexicon-eval <wav> [--scripted <text>]\n".utf8))
    return 2
}

exit(await runEval(arguments: CommandLine.arguments))
