// output-buffer: prints the default output device's IO buffer size, in frames,
// for the Live checks reading around a Lexicon cue (#339): Sounds sets 256 while
// its engine runs and puts the device's own size back when it stops.
//
//     swift scripts/output-buffer.swift
//
// Prints one line: buffer_frames=<n> device="<name>". Exit 0: read. Exit 1: no
// default output device, or the HAL refused the read. Reads only; changes nothing.
//
// The HAL answers for the device as this process sees it. That is the size any
// other app starts at, which is what a Lexicon buffer left behind would change.

import CoreAudio
import Foundation

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    return withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) == noErr
    }
}

var device = AudioObjectID(kAudioObjectUnknown)
guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &device),
      device != kAudioObjectUnknown else {
    FileHandle.standardError.write(Data("output-buffer: no default output device\n".utf8))
    exit(1)
}
var frames: UInt32 = 0
guard property(device, kAudioDevicePropertyBufferFrameSize, &frames) else {
    FileHandle.standardError.write(Data("output-buffer: the HAL refused the buffer size read\n".utf8))
    exit(1)
}
var name: Unmanaged<CFString>?
let named = property(device, kAudioObjectPropertyName, &name)
print("buffer_frames=\(frames) device=\"\(named ? (name?.takeRetainedValue() as String? ?? "") : "")\"")
