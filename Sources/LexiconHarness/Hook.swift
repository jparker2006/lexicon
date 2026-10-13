#if DEBUG
import Foundation
import LexiconDomain
import TestHooks

/// `lexicon-harness hook ...`: one test hook to the running Lexicon Dev, reply printed.
func hook(_ arguments: [String]) async throws {
    let command = hookCommand(arguments)
    var timeout = Duration.seconds(10)
    if case .capture(let seconds, let idle, _, _) = command { timeout += .seconds(seconds + (idle ?? 0)) }
    // The app waits `delay` seconds for a click into the field before it pastes.
    if case .insert(_, let delay) = command { timeout += .seconds(delay) }
    // A WAV plays at the speed of speech, then lands.
    if case .dictate(_, let delay) = command { timeout += .seconds(60 + (delay ?? 0)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    switch try await DevApp.hooks.send(command, timeout: timeout) {
    case .status(let status):
        print(String(decoding: try encoder.encode(status), as: UTF8.self))
    case .done:
        print("ok")
    case .soundPlayed(let latency):
        print("played in \(milliseconds(latency)) ms")
    case .capture(let measurement):
        print(String(decoding: try encoder.encode(measurement), as: UTF8.self))
    case .inserted(let insertion):
        print(String(decoding: try encoder.encode(insertion), as: UTF8.self))
    case .dictated(let dictation):
        print(String(decoding: try encoder.encode(dictation), as: UTF8.self))
    case .failed(let reason):
        fail("FAIL  \(reason)")
    }
}

/// The command a `hook` line asks for. A bad line prints the usage.
func hookCommand(_ arguments: [String]) -> TestHookCommand {
    switch arguments.first ?? "" {
    case "status" where arguments.count == 1:
        return .status
    case "dictate" where arguments.count == 2 || arguments.count == 4:
        var delay: Double?
        if arguments.count == 4 {
            guard arguments[2] == "--result-delay", let ms = Double(arguments[3]), ms >= 0 else { fail(usage, code: 64) }
            delay = ms / 1_000
        }
        return .dictate(wav: URL(filePath: arguments[1]).standardizedFileURL.path, resultDelay: delay)
    case "fn" where arguments.count >= 2:
        return fnKeys(arguments.dropFirst())
    case "key" where arguments == ["key", "esc"]:
        return .keys([.escape])
    case "sleep" where arguments.count == 1:
        return .sleep
    case "mic" where arguments == ["mic", "zeros"]:
        return .silenceMic
    case "audio" where arguments == ["audio", "drops"]:
        return .dropAudio
    case "indicator" where arguments.count == 2 || arguments.count == 3:
        guard let state = indicatorState(named: arguments[1], message: arguments.count == 3 ? arguments[2] : nil) else {
            fail(usage, code: 64)
        }
        return .indicator(state)
    case "capture" where arguments.count >= 2:
        return capture(seconds: arguments[1], options: arguments.dropFirst(2))
    case "privacy" where arguments.count == 2 || arguments.count == 4:
        return privacy(arguments)
    case "insert" where arguments.count >= 2:
        var words = arguments.dropFirst()
        var delay = 0.0
        if words.first == "--delay" {
            guard let seconds = words.dropFirst().first.flatMap(Double.init), seconds >= 0 else { fail(usage, code: 64) }
            delay = seconds
            words = words.dropFirst(2)
        }
        guard !words.isEmpty else { fail(usage, code: 64) }
        return .insert(text: words.joined(separator: " "), delay: delay)
    case "sound" where arguments.count == 2:
        guard let cue = SoundCue(rawValue: arguments[1]) else { fail(usage, code: 64) }
        return .sound(cue)
    default:
        fail(usage, code: 64)
    }
}

/// `fn down|up... [--shift]`: the edges in order, each with Shift held or not.
func fnKeys(_ words: ArraySlice<String>) -> TestHookCommand {
    let shift = words.last == "--shift"
    let edges = shift ? words.dropLast() : words
    guard !edges.isEmpty else { fail(usage, code: 64) }
    return .keys(edges.map { edge in
        switch edge {
        case "down": .fnDown(shift: shift)
        case "up": .fnUp(shift: shift)
        default: fail(usage, code: 64)
        }
    })
}

func capture(seconds: String, options: ArraySlice<String>) -> TestHookCommand {
    guard let seconds = Double(seconds), seconds > 0 else { fail(usage, code: 64) }
    var change = false
    var prepared, device: String?
    for option in options {
        switch option {
        case "prepared": prepared = "0.3"
        case _ where option.hasPrefix("prepared="): prepared = String(option.dropFirst("prepared=".count))
        case "change": change = true
        case _ where option.hasPrefix("device="): device = String(option.dropFirst("device=".count))
        default: fail(usage, code: 64)
        }
    }
    let idle = prepared.map { Double($0) }
    if idle == .some(nil) { fail(usage, code: 64) }
    return .capture(seconds: seconds, preparedIdle: idle ?? nil, deviceChange: change, deviceUID: device)
}

/// `privacy on|off [--always-private <ids>]`, with the ids comma-separated. An empty
/// list clears the always-private apps; no flag leaves them as they are.
func privacy(_ arguments: [String]) -> TestHookCommand {
    let mode: PrivacyMode
    switch arguments[1] {
    case "on": mode = .private
    case "off": mode = .standard
    default: fail(usage, code: 64)
    }
    guard arguments.count == 4 else { return .privacy(mode, alwaysPrivateApps: nil) }
    guard arguments[2] == "--always-private" else { fail(usage, code: 64) }
    return .privacy(mode, alwaysPrivateApps: arguments[3].split(separator: ",").map(String.init))
}
#endif
