// fn-key probe for docs/research/fn-key.md.
//
// Run from a terminal that has Accessibility and Input Monitoring:
//   swift docs/research/fn-key-probe.swift            # 30 s, observe only
//   swift docs/research/fn-key-probe.swift 60          # 60 s
//   swift docs/research/fn-key-probe.swift 30 --consume # also swallow fn flagsChanged
//
// It never calls a Request* permission API and never changes a system setting.
// It watches fn three ways at once (CGEventTap, NSEvent global monitor, IOHIDManager),
// logs every fn edge with its delivery latency, then prints hold and gap statistics
// you can use to tune hold-vs-tap and double-tap thresholds.
import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import IOKit.hid

let args = CommandLine.arguments.dropFirst()
let seconds = args.compactMap { Double($0) }.first ?? 30
let consume = args.contains("--consume")

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func machToNs(_ t: UInt64) -> UInt64 { t * UInt64(timebase.numer) / UInt64(timebase.denom) }
let start = nowNs()
func ms(_ ns: UInt64) -> String { String(format: "%8.3f", Double(ns) / 1e6) }

// MARK: - Environment

typealias GetUsage = @convention(c) () -> Int32
var effectiveFnUsage: Int32 = -1
if let carbon = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY),
   let get = dlsym(carbon, "TISGetFnUsageType") {
    effectiveFnUsage = unsafeBitCast(get, to: GetUsage.self)()
}
let fnUsageNames = [0: "Do Nothing", 1: "Change Input Source", 2: "Show Emoji & Symbols", 3: "Start Dictation"]
print("Input Monitoring (CGPreflightListenEventAccess):", CGPreflightListenEventAccess())
print("Accessibility (AXIsProcessTrusted):", AXIsProcessTrusted())
print("Secure Event Input on:", IsSecureEventInputEnabled())
print("Press globe key to:", effectiveFnUsage, fnUsageNames[Int(effectiveFnUsage)] ?? "unknown")
print("doubleClickInterval:", NSEvent.doubleClickInterval, "keyRepeatDelay:", NSEvent.keyRepeatDelay)
print("mode:", consume ? "CONSUME fn flagsChanged (default tap)" : "observe only (listen-only tap)")
print("Press fn for \(Int(seconds)) s: holds, single taps, double taps, fn+arrow.\n")

// MARK: - Recording

struct Edge { let source: String; let down: Bool; let at: UInt64; let latency: UInt64? }
var edges: [Edge] = []
func record(_ source: String, _ down: Bool, latency: UInt64?) {
    let t = nowNs()
    edges.append(Edge(source: source, down: down, at: t, latency: latency))
    let lat = latency.map { "latency \(ms($0)) ms" } ?? ""
    print("\(ms(t - start)) ms  \(source.padding(toLength: 6, withPad: " ", startingAt: 0)) fn \(down ? "DOWN" : "up  ")  \(lat)")
}

// MARK: - 1. CGEventTap (session level)

var tapFnDown = false
var tapPort: CFMachPort?
let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
tapPort = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap,
    options: consume ? .defaultTap : .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("tap disabled (\(type.rawValue)), re-enabling")
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown, tapFnDown {
            print("           tap    other key \(keyCode) while fn held (chord: cancel dictation)")
        }
        guard type == .flagsChanged, keyCode == 63 else { return Unmanaged.passUnretained(event) }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != tapFnDown else { return Unmanaged.passUnretained(event) }
        tapFnDown = down
        let lat = nowNs() &- event.timestamp
        record("tap", down, latency: lat < 1_000_000_000 ? lat : nil)
        return consume ? nil : Unmanaged.passUnretained(event)
    },
    userInfo: nil)
if let tapPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tapPort, 0), .commonModes)
    CGEvent.tapEnable(tap: tapPort, enable: true)
} else {
    print("CGEventTap: creation failed (missing permission)")
}

// MARK: - 2. NSEvent global monitor

var nsFnDown = false
let nsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in
    guard e.keyCode == 63 else { return }
    let down = e.modifierFlags.contains(.function)
    guard down != nsFnDown else { return }
    nsFnDown = down
    let lat = nowNs() &- UInt64(e.timestamp * 1e9)
    record("nsmon", down, latency: lat < 1_000_000_000 ? lat : nil)
}
if nsMonitor == nil { print("NSEvent monitor: failed") }

// MARK: - 3. IOHIDManager on keyboards (Apple vendor fn usage)

let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hid, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                                    kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
IOHIDManagerRegisterInputValueCallback(hid, { _, _, _, value in
    let el = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el)
    // 0x00FF/0x03: Apple Vendor Top Case fn. 0xFF01/0x03: Apple Vendor Keyboard Function.
    guard (page == 0x00FF || page == 0xFF01), usage == 0x03 else { return }
    let down = IOHIDValueGetIntegerValue(value) != 0
    let lat = nowNs() &- machToNs(IOHIDValueGetTimeStamp(value))
    record(String(format: "hid%02X", page & 0xFF), down, latency: lat < 1_000_000_000 ? lat : nil)
}, nil)
IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let hidOpen = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
print("IOHIDManagerOpen:", hidOpen == kIOReturnSuccess ? "ok" : String(format: "0x%08x", hidOpen))

// MARK: - Summary

func summary() {
    print("\n--- summary ---")
    for source in Set(edges.map(\.source)).sorted() {
        let es = edges.filter { $0.source == source }
        let lats = es.compactMap(\.latency).sorted()
        var holds: [Double] = [], gaps: [Double] = []
        var lastDown: UInt64?, lastUp: UInt64?
        for e in es {
            if e.down {
                if let lastUp { gaps.append(Double(e.at - lastUp) / 1e6) }
                lastDown = e.at
            } else if let d = lastDown {
                holds.append(Double(e.at - d) / 1e6)
                lastUp = e.at
            }
        }
        let p50 = lats.isEmpty ? "n/a" : ms(lats[lats.count / 2])
        let pmax = lats.last.map(ms) ?? "n/a"
        print("\(source): \(es.count) edges, latency p50 \(p50) ms max \(pmax) ms")
        print("  holds ms: \(holds.map { String(format: "%.0f", $0) }.joined(separator: " "))")
        print("  up-to-next-down gaps ms: \(gaps.map { String(format: "%.0f", $0) }.joined(separator: " "))")
    }
    exit(0)
}
Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in summary() }
signal(SIGINT) { _ in summary() }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
