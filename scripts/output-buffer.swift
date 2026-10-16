// output-buffer: prints the default output device's IO buffer size, in frames,
// as any other app would find it. For the Live checks reading around a Lexicon
// cue: Sounds sets 256 while its engine runs and puts the device's own size back
// when it stops, so the size read before a cue and after the stop must match.
//
//     swift scripts/output-buffer.swift
//
// Prints one line: buffer_frames=<n>. Exit 0: read. Exit 1: no default output
// device, or the HAL refused the read. Reads only; changes nothing.
//
// The HAL answers per process: while one process holds 256, another still reads
// its own 512 (measured on this Mac). So a match shows no size leaked to other
// apps; it cannot see the 256 inside Lexicon itself.

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
// No device name: one can carry a person's name, and this line goes into Live checks results.
print("buffer_frames=\(frames)")
