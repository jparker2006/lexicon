import Foundation
import LexiconDomain
import LexiconCore
import History
import LocalParakeet

// `lexicon-eval`: dev tool, never shipped. Runs the real Conductor headless on
// Test set audio, in seconds, for the Python scorer (#15).
//
//   swift run lexicon-eval run --testset <dir> [--split dev] [--model cloud:...|local:...]
//                              [--pace realtime|fast] [--private]
//       reads <dir>/manifest.jsonl (NeMo fields + speech_end, terms, context, split),
//       writes one JSON line per entry to stdout:
//       {"id", "hypothesis", "model", "lag_ms", "attempts": [{model, result, text, latency_ms}]}
//       piped to: uv run --with jiwer==4.0.0 score.py - baselines/wispr-latest.jsonl
//
//   swift run lexicon-eval export --from <app support root> --out <dir>
//       copies pinned Dictations (and Fix-confirmed text) out of History into a
//       Test set folder outside the repo. Opens history.sqlite read-only.
//
// Keys come from LEXICON_KEY_* environment variables (Secrets(.environment)).

struct ManifestEntry: Decodable {
    let audio_filepath: String
    let text: String
    let duration: Double?
    let speech_end: Double?
    let terms: [String]?
    let split: String?
}

func runEval(arguments: [String]) async -> Int32 {
    // TODO: for each entry: let system = try HeadlessSystem.make(paths: .temporary(), context: entry context,
    //   preferences: from flags, local: ParakeetTranscriber(paths: <the dev app's root, for its weights>));
    //   let result = await system.conductor.dictate(file: url, pace: pace); print JSON line.
    // One HeadlessSystem per run (not per entry) so the local model stays resident, like the app.
    fatalError("not implemented")
}

exit(await runEval(arguments: CommandLine.arguments))
