// PROTOTYPE, throwaway. Feel test for "Re-speak fix: how it feels"
// (https://github.com/jparker2006/lexicon/issues/23). Lives on branch prototype/respeak only. Never ship.
//
// Plain fn hold dictates (Apple on-device speech, no word hints, so it makes real tech-word mistakes).
// Re-speak triggers, all live at once:
//   fn + Shift hold   say the right word, release
//   Right Option hold say the right word, release
//   spoken cue        fn hold and say "fix Supabase" / "I meant Supabase"
//   auto-detect       (menu toggle) a short fn dictation right after another one; Jev decides if it's a fix
//   your selection    select the wrong word first, then any trigger replaces exactly that
import AppKit
import AVFoundation
import Speech
import ApplicationServices

// MARK: Knobs (menu bar)

enum Seeing: String, CaseIterable { case pill = "Pill by the cursor", highlight = "Pill + select the guess while deciding", sound = "Sounds only" }
enum Unsure: String, CaseIterable { case choose = "Show choices (press 1, 2, 3)", guess = "Use the best guess anyway", nothing = "Change nothing" }
enum Trigger: String { case fn = "fn hold", fnShift = "fn + Shift", rightOption = "Right Option", cue = "spoken cue", auto = "auto-detect", selection = "your selection" }

var seeing = Seeing.pill
var unsure = Unsure.choose
var extraDelayMs = 0
var autoDetect = false
let unsureBelow = 0.75
let ourEventTag: Int64 = 0x1E5C0
let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]
let techTerms = ["Supabase", "Vercel", "Postgres", "PostgreSQL", "Kubernetes", "TypeScript", "JavaScript", "GitHub", "Swift", "AppKit",
                 "Xcode", "Jev", "TypeSafe", "OpenRouter", "Lexicon", "Wispr", "Claude", "Codex", "Anthropic", "Next.js", "React",
                 "Tailwind", "Prisma", "Cloudflare", "Redis", "Docker", "npm", "pnpm", "Bun", "Vite", "Electron", "FluidAudio",
                 "Parakeet", "SQLite", "Glox", "Haiku", "Opus", "Sonnet", "JSON", "OAuth", "webhook", "localhost", "pstack", "gstack",
                 "SwiftPM", "Muse", "Cartesia", "CGEventTap", "URLSession", "Keychain", "repo", "PR", "CLI", "API"]

// MARK: Small helpers

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func ms(_ a: Double, _ b: Double) -> Int { Int(((b - a) * 1000).rounded()) }
let logPath = NSHomeDirectory() + "/Library/Logs/LexiconRespeakProto.log"
let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    let line = clock.string(from: Date()) + " " + s + "\n"
    print(line, terminator: "")
    if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8)) }
}
func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
func play(_ name: String) { NSSound(named: name)?.play() }

func typesafeKey() -> String? {
    guard let env = try? String(contentsOfFile: NSHomeDirectory() + "/code/lexicon/.env", encoding: .utf8) else { return nil }
    for raw in env.split(separator: "\n") {
        var l = raw.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
        if l.hasPrefix("TYPESAFE_API_KEY=") { return String(l.dropFirst(17)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
    }
    return nil
}

// MARK: Sound-alike matching (stand-in for Double Metaphone)

func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
func soundKey(_ s: String) -> String {
    let c = Array(letters(s)); var out: [Character] = []
    for (i, ch) in c.enumerated() {
        let m: Character
        switch ch {
        case "a", "e", "i", "o", "u", "y", "h", "w": if i == 0 { m = "A" } else { continue }
        case "b", "p": m = "P"
        case "d", "t": m = "T"
        case "c": m = (i + 1 < c.count && "eiy".contains(c[i + 1])) ? "S" : "K"
        case "g", "k", "q", "x": m = "K"
        case "v", "f": m = "F"
        case "s", "z": m = "S"
        default: m = Character(ch.uppercased())
        }
        if out.last != m { out.append(m) }
    }
    return String(out)
}
func lev(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
    var prev = Array(0...b.count), cur = prev
    for i in 1...a.count {
        cur[0] = i
        for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        prev = cur
    }
    return prev[b.count]
}
func sim(_ a: String, _ b: String) -> Double { let m = max(a.count, b.count); return m == 0 ? 1 : 1 - Double(lev(Array(a), Array(b))) / Double(m) }

struct Cand { let text: String; let range: NSRange; var score: Double }

func candidates(in text: NSString, upTo caret: Int, heard: String) -> [Cand] {
    let start = max(0, caret - 400)
    var words: [NSRange] = []
    text.enumerateSubstrings(in: NSRange(location: start, length: caret - start), options: .byWords) { _, r, _, _ in words.append(r) }
    let hk = soundKey(heard), hl = letters(heard)
    var best: [String: Cand] = [:]
    for i in words.indices {
        for n in 1...3 where i + n <= words.count {
            let r = NSUnionRange(words[i], words[i + n - 1]); let t = text.substring(with: r)
            if t == heard || t.contains("\n") { continue }
            let tl = letters(t)
            let s = 0.6 * sim(soundKey(t), hk) + 0.4 * sim(tl, hl) + 0.05 * Double(r.location - start) / Double(max(1, caret - start))
            if best[tl] == nil || best[tl]!.score < s { best[tl] = Cand(text: t, range: r, score: s) }
        }
    }
    var picked: [Cand] = []
    for c in best.values.sorted(by: { $0.score > $1.score }) where !picked.contains(where: { NSIntersectionRange($0.range, c.range).length > 0 }) {
        picked.append(c); if picked.count == 5 { break }
    }
    return picked
}

// MARK: Jev

let jevURL = URL(string: "https://api.typesafe.ai/v1/systemone")!
let jevKey = typesafeKey()
let net = URLSession(configuration: .default)
struct JevAnswer { var pick = ""; var p = 0.0; var probs: [String: Double] = [:]; var isCorrection: Double?; var ms = 0; var error: String? }

func warmJev() { var r = URLRequest(url: jevURL); r.httpMethod = "HEAD"; net.dataTask(with: r).resume() }

func askJev(app: String, before: String, heard: String, cands: [Cand], askCorrection: Bool, done: @escaping (JevAnswer) -> Void) {
    guard let key = jevKey else { return done(JevAnswer(error: "no TYPESAFE_API_KEY")) }
    var cs: [String: Any] = [:], crit: [String: Any] = [:]
    for (i, c) in cands.enumerated() { cs["c\(i + 1)"] = ["text": c.text, "sound": soundKey(c.text)]; crit["c\(i + 1)"] = "candidate c\(i + 1)" }
    crit["none"] = "respoken does not replace any candidate"
    var q: [String: Any] = ["target": ["type": "choice", "criteria": crit, "instructions": [
        "question": "Which span of `text_before_cursor` was the user correcting when they said `respoken`?",
        "hint": "A correction usually sounds like the span it replaces. Compare `respoken_sound` with each candidate's `sound`, and prefer the span that reads wrong in context."]]]
    if askCorrection {
        q["is_correction"] = ["type": "noul", "instructions": "Is `respoken` a correction of a span in `text_before_cursor`, rather than new text the user wants to add after it?"]
    }
    let body: [String: Any] = ["model": "jev-1.13.0", "questions": q, "state": [
        "app": app, "text_before_cursor": before, "respoken": heard, "respoken_sound": soundKey(heard), "candidates": cs]]
    var r = URLRequest(url: jevURL); r.httpMethod = "POST"; r.timeoutInterval = 1.5
    r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try! JSONSerialization.data(withJSONObject: body)
    let t = now()
    net.dataTask(with: r) { data, resp, err in
        var a = JevAnswer(); a.ms = ms(t, now())
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if let data, status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let answers = obj["answers"] as? [String: Any], let target = answers["target"] as? [String: Any] {
            a.pick = target["choice"] as? String ?? ""
            a.probs = (target["probabilities"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            a.p = a.probs[a.pick] ?? 0
            a.isCorrection = ((answers["is_correction"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        } else { a.error = err?.localizedDescription ?? "HTTP \(status)" }
        DispatchQueue.main.async { done(a) }
    }.resume()
}

// MARK: Other apps' text (Accessibility + keys)

struct Field { let el: AXUIElement?; let text: NSString; let caret: Int; let selLen: Int; let pid: pid_t; let app: String; let bundle: String; let synthetic: Bool }

func manualAX(_ pid: pid_t) { AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue) }

func readField() -> Field? {
    guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = front.processIdentifier, appEl = AXUIElementCreateApplication(pid)
    manualAX(pid)
    AXUIElementSetMessagingTimeout(appEl, 0.25)
    var v: CFTypeRef?, sv: CFTypeRef?, rv: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &v) == .success, let fv = v else { return nil }
    let el = fv as! AXUIElement
    guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &sv) == .success, let s = sv as? String,
          AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rv) == .success, let r = rv else { return nil }
    var range = CFRange(); AXValueGetValue(r as! AXValue, .cfRange, &range)
    return Field(el: el, text: s as NSString, caret: range.location, selLen: range.length, pid: pid,
                 app: front.localizedName ?? "?", bundle: front.bundleIdentifier ?? "?", synthetic: false)
}

func selection(_ el: AXUIElement) -> CFRange? {
    var rv: CFTypeRef?; var range = CFRange()
    guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rv) == .success, let r = rv else { return nil }
    AXValueGetValue(r as! AXValue, .cfRange, &range); return range
}
func axSelect(_ el: AXUIElement, _ loc: Int, _ len: Int) -> Bool {
    var r = CFRange(location: loc, length: len)
    guard AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!) == .success,
          let back = selection(el) else { return false }
    return back.location == loc && back.length == len
}
func axValue(_ el: AXUIElement) -> String? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v); return v as? String }

func caretRect(_ f: Field?) -> NSRect? {
    guard let f, let el = f.el else { return nil }
    var r = CFRange(location: max(0, f.caret - 1), length: f.caret > 0 ? 1 : 0); var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, AXValueCreate(.cfRange, &r)!, &out) == .success,
          let o = out else { return nil }
    var rect = CGRect.zero; AXValueGetValue(o as! AXValue, .cgRect, &rect)
    guard rect.height > 0, let top = NSScreen.screens.first?.frame.height else { return nil }
    return NSRect(x: rect.maxX, y: top - rect.maxY, width: 1, height: rect.height)
}

let keySource = CGEventSource(stateID: .hidSystemState)
func key(_ code: CGKeyCode, _ flags: CGEventFlags = [], times: Int = 1) {
    for _ in 0..<max(0, times) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down)!
            e.flags = flags; e.setIntegerValueField(.eventSourceUserData, value: ourEventTag); e.post(tap: .cghidEventTap)
        }
    }
}

func paste(_ text: String) {
    let pb = NSPasteboard.general
    let saved = (pb.pasteboardItems ?? []).map { item in item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) } }
    pb.clearContents(); pb.setString(text, forType: .string)
    let mark = pb.changeCount
    key(9, .maskCommand)
    after(0.5) {
        guard pb.changeCount == mark, !saved.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(saved.map { d in let i = NSPasteboardItem(); for (t, v) in d { i.setData(v, forType: t) }; return i })
    }
}

// MARK: Pill

final class Pill {
    let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    let label = NSTextField(labelWithString: "")
    var hideToken = 0
    init() {
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(); fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 13, weight: .medium); label.textColor = .labelColor; label.maximumNumberOfLines = 6
        fx.addSubview(label); panel.contentView = fx
    }
    func show(_ text: String, near: NSRect?, for seconds: Double? = nil) {
        label.stringValue = text; label.sizeToFit()
        let size = NSSize(width: label.frame.width + 22, height: label.frame.height + 12)
        label.frame.origin = NSPoint(x: 11, y: 6)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        var o: NSPoint
        if let r = near { o = NSPoint(x: r.minX - 8, y: r.minY - size.height - 6); if o.y < screen.frame.minY { o.y = r.maxY + 6 } }
        else { o = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 90) }
        panel.setFrame(NSRect(origin: o, size: size), display: true); panel.orderFrontRegardless()
        hideToken += 1; let t = hideToken
        if let s = seconds { after(s) { if self.hideToken == t { self.panel.orderOut(nil) } } }
    }
    func hide() { hideToken += 1; panel.orderOut(nil) }
}

// MARK: Recording

final class Rec {
    var trigger: Trigger
    let field: Field?
    let started = now()
    var released = 0.0
    let engine = AVAudioEngine()
    let req = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    var text = "", final = false, finished = false
    var onFinal: (() -> Void)?
    init(_ t: Trigger, _ f: Field?) { trigger = t; field = f }
    var isFix: Bool { trigger == .fnShift || trigger == .rightOption }
}

// MARK: The app

final class Proto: NSObject, NSApplicationDelegate {
    static let shared = Proto()
    let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    let pill = Pill()
    var status: NSStatusItem!
    var tap: CFMachPort?
    var rec: Rec?
    var fnDown = false, fnDownAt = 0.0, roptDown = false
    var lastInsert: (text: String, pid: pid_t, at: Double)?
    var keysSinceInsert = 0
    var choosing: (cands: [Cand], heard: String, field: Field, trigger: Trigger, t0: Double)?

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        log("launch: jev key \(jevKey == nil ? "MISSING" : "found"), on-device speech \(recognizer.supportsOnDeviceRecognition)")
        SFSpeechRecognizer.requestAuthorization { log("speech auth: \($0.rawValue)") }
        AVCaptureDevice.requestAccess(for: .audio) { log("mic auth: \($0)") }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        startTapWhenTrusted()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { manualAX(a.processIdentifier) }
        }
        if let f = NSWorkspace.shared.frontmostApplication { manualAX(f.processIdentifier) }
        warmJev()
    }

    func startTapWhenTrusted() {
        guard AXIsProcessTrusted() else { status.button?.title = "Re ⚠︎"; return after(1) { self.startTapWhenTrusted() } }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, e, _ in
            let me = Proto.shared
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }; return Unmanaged.passUnretained(e) }
            if e.getIntegerValueField(.eventSourceUserData) == ourEventTag { return Unmanaged.passUnretained(e) }
            return me.handle(type, e) ? nil : Unmanaged.passUnretained(e)
        }, userInfo: nil)
        guard let tap else { log("tap failed"); return after(1) { self.startTapWhenTrusted() } }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        status.button?.title = "Re"
        log("tap on")
    }

    // Returns true to swallow the event.
    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown {
            if let c = choosing {
                if code == 53 { choosing = nil; pill.show("Left it alone", near: caretRect(c.field), for: 1.2); log("choice: esc"); return true }
                if let i = [18: 0, 19: 1, 20: 2][code], i < c.cands.count { choosing = nil; log("choice: \(i + 1)"); apply(c.cands[i], c.heard, c.field, c.trigger, c.t0, note: "you picked"); return true }
            }
            keysSinceInsert += 1
            if let r = rec {
                if code == 53 { cancel(r, "Esc"); return true }
                if r.trigger == .rightOption || (fnDown && now() - fnDownAt < 0.3) { cancel(r, "key pressed during hold") }
            }
            return false
        }
        let flags = e.flags
        switch code {
        case 63:
            let down = flags.contains(.maskSecondaryFn)
            if down && !fnDown { fnDown = true; fnDownAt = now(); if rec == nil { begin(flags.contains(.maskShift) ? .fnShift : .fn) } }
            else if !down && fnDown { fnDown = false; if let r = rec, r.trigger == .fn || r.trigger == .fnShift { now() - fnDownAt < 0.3 ? cancel(r, "tap") : end(r) } }
        case 56, 60:
            if flags.contains(.maskShift), fnDown, let r = rec, r.trigger == .fn { r.trigger = .fnShift; showListening(r) }
        case 61:
            let down = flags.rawValue & 0x40 != 0
            if down && !roptDown { roptDown = true; if rec == nil { begin(.rightOption) } }
            else if !down && roptDown { roptDown = false; if let r = rec, r.trigger == .rightOption { now() - r.started < 0.2 ? cancel(r, "tap") : end(r) } }
        default: break
        }
        return false
    }

    func currentField() -> Field? {
        if let f = readField() { return f }
        guard let li = lastInsert, keysSinceInsert == 0, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == li.pid else { return nil }
        let t = li.text as NSString
        return Field(el: nil, text: t, caret: t.length, selLen: 0, pid: li.pid, app: front.localizedName ?? "?", bundle: front.bundleIdentifier ?? "?", synthetic: true)
    }

    func begin(_ t: Trigger) {
        choosing = nil
        let r = Rec(t, currentField()); rec = r
        warmJev()
        r.req.shouldReportPartialResults = true
        r.req.addsPunctuation = !r.isFix
        var hints = techTerms
        if let f = r.field { f.text.enumerateSubstrings(in: NSRange(location: max(0, f.caret - 400), length: f.caret - max(0, f.caret - 400)), options: .byWords) { w, _, _, _ in if let w, w.count > 2 { hints.append(w) } } }
        if r.isFix { r.req.contextualStrings = Array(hints.prefix(100)) }  // plain fn gets no hints, so it makes real mistakes
        r.req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let input = r.engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { b, _ in r.req.append(b) }
        r.engine.prepare()
        do { try r.engine.start() } catch { log("mic error \(error)"); rec = nil; return }
        r.task = recognizer.recognitionTask(with: r.req) { res, err in DispatchQueue.main.async {
            if let res { r.text = res.bestTranscription.formattedString }
            if res?.isFinal == true || err != nil { r.final = true }
            if !r.finished, self.rec === r { self.showListening(r) }
            r.onFinal?()
        } }
        play("Tink")
        showListening(r)
        log("begin \(t.rawValue) in \(r.field?.app ?? "?") field=\(r.field == nil ? "none" : (r.field!.synthetic ? "bookkeeping" : "AX")) caret=\(r.field?.caret ?? -1) sel=\(r.field?.selLen ?? 0)")
    }

    func showListening(_ r: Rec) {
        if r.isFix {
            if seeing == .sound { return }
            let heard = r.text.isEmpty ? "say the right word" : "“\(r.text)”"
            pill.show("Fix: \(heard)", near: caretRect(r.field) )
        } else {
            pill.show("● " + (r.text.isEmpty ? "listening" : r.text.suffix(60)), near: nil)
        }
    }

    func stopAudio(_ r: Rec) {
        r.engine.inputNode.removeTap(onBus: 0); r.engine.stop(); r.req.endAudio()
    }

    func cancel(_ r: Rec, _ why: String) {
        r.finished = true; stopAudio(r); r.task?.cancel(); rec = nil; pill.hide(); log("cancel: \(why)")
    }

    func end(_ r: Rec) {
        r.released = now(); r.finished = true; rec = nil
        if r.isFix && seeing != .sound { pill.show("Fix: “\(r.text)” …", near: caretRect(r.field)) }
        after(0.12) { self.stopAudio(r) }
        var fired = false
        let go = {
            if fired { return }; fired = true; r.onFinal = nil
            self.route(r, speechMs: ms(r.released, now()))
        }
        r.onFinal = { if r.final { go() } }
        after(2.0) { go() }
    }

    func route(_ r: Rec, speechMs: Int) {
        let plainText = r.text.trimmingCharacters(in: .whitespaces)
        log("heard “\(plainText)” as \(r.trigger.rawValue) speech=\(speechMs)ms")
        if r.isFix { return fix(snap(clean(plainText)), r.trigger, r.field, r.released, speechMs, autoFallback: nil) }
        let lower = plainText.lowercased()
        for cue in ["fix ", "fixed ", "fix: ", "fix, ", "i meant ", "i mean ", "correction "] where lower.hasPrefix(cue) {
            return fix(snap(clean(String(plainText.dropFirst(cue.count)))), .cue, r.field, r.released, speechMs, autoFallback: nil)
        }
        let words = plainText.split(separator: " ").count
        if autoDetect, words > 0, words <= 3, let li = lastInsert, now() - li.at < 30, r.field != nil {
            return fix(snap(clean(plainText)), .auto, r.field, r.released, speechMs, autoFallback: plainText)
        }
        insert(plainText, r.field)
    }

    // Stand-in for the Lexicon: a re-spoken word that sounds like a known term becomes that term.
    func snap(_ s: String) -> String {
        guard letters(s).count >= 5, s.split(separator: " ").count <= 3 else { return s }
        let best = techTerms.filter { letters($0).count >= 4 }.map { t in (t, 0.6 * sim(soundKey(t), soundKey(s)) + 0.4 * sim(letters(t), letters(s))) }.max { $0.1 < $1.1 }!
        if best.1 >= 0.62 { log("snap “\(s)” → “\(best.0)” \(String(format: "%.2f", best.1))"); return best.0 }
        return s
    }

    func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?;:"))) }

    func insert(_ text: String, _ f: Field?) {
        guard !text.isEmpty else { pill.show("Heard nothing", near: nil, for: 1.0); return }
        var t = text
        if let f, f.caret > 0, f.caret <= f.text.length, let prev = f.text.substring(with: NSRange(location: f.caret - 1, length: 1)).unicodeScalars.first,
           !CharacterSet.whitespacesAndNewlines.contains(prev) { t = " " + t }
        paste(t)
        lastInsert = (t, NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, now()); keysSinceInsert = 0
        pill.hide(); play("Pop")
        log("insert “\(t)”")
    }

    func fix(_ heard: String, _ trigger: Trigger, _ field: Field?, _ t0: Double, _ speechMs: Int, autoFallback: String?) {
        let near = caretRect(field)
        guard !heard.isEmpty else { pill.show("Didn't catch the word", near: near, for: 1.5); play("Basso"); return log("fix: empty") }
        guard let f = field else { pill.show("Can't read this text box", near: near, for: 2); play("Basso"); return log("fix: no field") }
        if f.selLen > 0, !f.synthetic {
            let r = NSRange(location: f.caret, length: f.selLen)
            return apply(Cand(text: f.text.substring(with: r), range: r, score: 1), heard, f, .selection, t0, note: "selection, speech \(speechMs)")
        }
        let cands = candidates(in: f.text, upTo: min(f.caret, f.text.length), heard: heard)
        guard let top = cands.first else { pill.show("Nothing near the cursor to fix", near: near, for: 1.5); play("Basso"); return log("fix: no candidates") }
        if seeing == .highlight, let el = f.el { _ = axSelect(el, top.range.location, top.range.length) }
        if seeing != .sound { pill.show("“\(heard)” → finding the word…", near: near) }
        let start = max(0, f.caret - 400)
        let before = f.text.substring(with: NSRange(location: start, length: min(f.caret, f.text.length) - start))
        askJev(app: f.app, before: before, heard: heard, cands: cands, askCorrection: trigger == .auto) { a in
            let ranked: [Cand]
            var pick: Cand?, p: Double
            if a.error == nil {
                ranked = cands.enumerated().sorted { (a.probs["c\($0.offset + 1)"] ?? 0) > (a.probs["c\($1.offset + 1)"] ?? 0) }.map { $0.element }
                if a.pick.hasPrefix("c"), let i = Int(a.pick.dropFirst()), i >= 1, i <= cands.count { pick = cands[i - 1] }
                p = a.p
            } else { ranked = cands; pick = top; p = min(top.score, 0.99) }
            let summary = cands.enumerated().map { "c\($0.offset + 1) “\($0.element.text)” local \(String(format: "%.2f", $0.element.score)) jev \(String(format: "%.2f", a.probs["c\($0.offset + 1)"] ?? -1))" }.joined(separator: " | ")
            log("fix \(trigger.rawValue) heard=“\(heard)” jev=\(a.error ?? "\(a.pick) p=\(String(format: "%.2f", a.p)) isCorr=\(a.isCorrection.map { String(format: "%.2f", $0) } ?? "-") \(a.ms)ms") :: \(summary)")
            if let fb = autoFallback, (a.isCorrection ?? 0) < 0.6 || pick == nil || p < unsureBelow {
                if seeing == .highlight, let el = f.el { _ = axSelect(el, f.caret, f.selLen) }
                log("auto: not a fix, typing it"); return self.insert(fb, f)
            }
            let note = "speech \(speechMs) · Jev \(a.error == nil ? "\(a.ms)" : "failed, local") ms"
            if let pick, p >= unsureBelow { return self.later { self.apply(pick, heard, f, trigger, t0, note: note) } }
            switch unsure {
            case .guess: self.later { self.apply(pick ?? top, heard, f, trigger, t0, note: note + " · unsure \(String(format: "%.2f", p))") }
            case .nothing:
                if seeing == .highlight, let el = f.el { _ = axSelect(el, f.caret, f.selLen) }
                self.pill.show("Not sure which word. Nothing changed.", near: near, for: 2); play("Basso")
            case .choose:
                if seeing == .highlight, let el = f.el { _ = axSelect(el, f.caret, f.selLen) }
                let opts = Array(ranked.prefix(3))
                self.choosing = (opts, heard, f, trigger, t0)
                self.pill.show("Which one becomes “\(heard)”?\n" + opts.enumerated().map { "  \($0.offset + 1)  \($0.element.text)" }.joined(separator: "\n") + "\n  esc  leave it", near: near)
                play("Morse")
                let token = self.pill.hideToken
                after(8) { if self.pill.hideToken == token, self.choosing != nil { self.choosing = nil; self.pill.hide() } }
            }
        }
    }

    func later(_ f: @escaping () -> Void) { extraDelayMs == 0 ? f() : after(Double(extraDelayMs) / 1000, f) }

    func apply(_ c: Cand, _ heard: String, _ f: Field, _ trigger: Trigger, _ t0: Double, note: String) {
        var word = heard
        if let first = word.first, first.isLowercase, c.text.first?.isUppercase == true { word = first.uppercased() + word.dropFirst() }
        let delta = (word as NSString).length - c.range.length
        let tail = max(0, min(f.caret, f.text.length) - NSMaxRange(c.range))
        let tApply = now()
        var how: String
        if let el = f.el, axSelect(el, c.range.location, c.range.length) {
            how = "AX select + paste"
            let old = axValue(el)
            paste(word)
            let newCaret = f.caret >= NSMaxRange(c.range) ? f.caret + delta : f.caret
            var tries = 0
            func settle() {
                tries += 1
                if axValue(el) != old || tries > 30 {
                    _ = axSelect(el, newCaret, 0)
                    self.done(c, word, f, trigger, t0, tApply, how + (tries > 30 ? " (no change seen)" : ""), note)
                } else { after(0.01, settle) }
            }
            after(0.01, settle)
            return
        }
        if terminals.contains(f.bundle) {
            how = "keys: left + backspace + paste"
            key(123, times: tail); key(51, times: c.range.length)
        } else {
            how = "keys: left + shift-left + paste"
            key(123, times: tail); key(123, .maskShift, times: c.range.length)
        }
        paste(word); key(124, times: tail)
        if f.synthetic, let li = lastInsert { lastInsert = ((li.text as NSString).replacingCharacters(in: c.range, with: word), li.pid, li.at) }
        done(c, word, f, trigger, t0, tApply, how, note)
    }


    func done(_ c: Cand, _ word: String, _ f: Field, _ trigger: Trigger, _ t0: Double, _ tApply: Double, _ how: String, _ note: String) {
        let total = ms(t0, now())
        log("applied \(trigger.rawValue): “\(c.text)” → “\(word)” in \(f.app) via \(how); apply \(ms(tApply, now()))ms, release→done \(total)ms (\(note))")
        play("Pop")
        if seeing != .sound { pill.show("\(c.text) → \(word)   \(total) ms\n\(note) · paste \(ms(tApply, now()))", near: caretRect(readField() ?? f), for: 2.5) }
    }

    // MARK: Menu

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Re ⚠︎"
        let m = NSMenu()
        for line in ["Re-speak prototype (throwaway)", "fn hold: dictate (no word hints)", "fn + Shift hold: re-speak", "Right Option hold: re-speak",
                     "fn hold + “fix …” / “I meant …”: re-speak", "Select a word first: replaces exactly that"] {
            m.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
        }
        m.addItem(.separator())
        let auto = NSMenuItem(title: "Auto-detect short re-speaks (Jev decides)", action: #selector(toggleAuto(_:)), keyEquivalent: ""); auto.target = self
        m.addItem(auto)
        m.addItem(submenu("While it decides", Seeing.allCases.map { $0.rawValue }, #selector(pickSeeing(_:))) { $0 == seeing.rawValue })
        m.addItem(submenu("Extra delay", ["0 ms", "300 ms", "700 ms", "1500 ms"], #selector(pickDelay(_:))) { $0 == "\(extraDelayMs) ms" })
        m.addItem(submenu("When unsure", Unsure.allCases.map { $0.rawValue }, #selector(pickUnsure(_:))) { $0 == unsure.rawValue })
        m.addItem(.separator())
        let lg = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: ""); lg.target = self; m.addItem(lg)
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        status.menu = m
    }
    func submenu(_ title: String, _ items: [String], _ sel: Selector, on: (String) -> Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), sub = NSMenu()
        for t in items { let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; i.state = on(t) ? .on : .off; sub.addItem(i) }
        item.submenu = sub; return item
    }
    func radio(_ s: NSMenuItem) { s.menu?.items.forEach { $0.state = $0 === s ? .on : .off } }
    @objc func toggleAuto(_ s: NSMenuItem) { autoDetect.toggle(); s.state = autoDetect ? .on : .off; log("auto-detect \(autoDetect)") }
    @objc func pickSeeing(_ s: NSMenuItem) { seeing = Seeing(rawValue: s.title)!; radio(s); log("seeing: \(s.title)") }
    @objc func pickDelay(_ s: NSMenuItem) { extraDelayMs = Int(s.title.split(separator: " ")[0])!; radio(s); log("extra delay \(extraDelayMs)") }
    @objc func pickUnsure(_ s: NSMenuItem) { unsure = Unsure(rawValue: s.title)!; radio(s); log("unsure: \(s.title)") }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
}


// MARK: Self-test (no UI): ranking plus one real Jev call

if CommandLine.arguments.contains("--selftest") {
    let text = "okay now wire the auth callback into super base and then redeploy to vercel" as NSString
    let cands = candidates(in: text, upTo: text.length, heard: "Supabase")
    for c in cands { print(String(format: "%.2f", c.score), c.text, soundKey(c.text)) }
    print("key:", jevKey == nil ? "missing" : "found")
    for w in ["Super base", "super Bass", "Super", "Versailles", "callback", "red deployed", "get hub", "post grass", "type script", "hello", "base", "close", "verse", "cool", "react", "review", "codecs", "clawed", "result", "Jeff", "brew", "open", "release", "push"] { print("snap", w, "->", Proto.shared.snap(w)) }
    askJev(app: "Claude", before: text as String, heard: "Supabase", cands: cands, askCorrection: true) { a in
        print("jev:", a.error ?? "\(a.pick) p=\(a.p) isCorrection=\(a.isCorrection ?? -1) \(a.ms) ms"); exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = Proto.shared
app.run()
