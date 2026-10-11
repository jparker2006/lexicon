import AudioToolbox
import Foundation
import LexiconDomain

/// One open `audio/<id>.caf` of 16 kHz mono Int16, written with
/// `AudioFileWritePackets` (synchronous: each call reaches the kernel, so an app
/// crash keeps every packet written). The data chunk's size stays -1 until
/// `close`, which the CAF spec defines as "read to the end of the file".
///
/// Banned here (crash test, #4): `ExtAudioFileWriteAsync` (lost whole
/// recordings), FLAC through ExtAudioFile (unreadable after a crash), and WAV
/// through AudioFile (reads back empty after a crash).
///
/// Confined to the writer queue.
final class CAFWriter {
    struct Failure: Error {
        let step: String
        let status: Int32
    }

    static let format = AudioStreamBasicDescription(
        mSampleRate: Double(PCM16k.sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )

    private var file: AudioFileID?
    /// AudioFile does not expose its descriptor. fsync and F_FULLFSYNC act on the
    /// file (the vnode), not on one descriptor's writes, so a second read-only
    /// descriptor can flush what AudioFile wrote.
    private var syncDescriptor: Int32
    private var packets: Int64 = 0

    init(creating url: URL) throws(Failure) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var format = Self.format
        var id: AudioFileID?
        let status = AudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, .eraseFile, &id)
        guard status == noErr, let id else { throw Failure(step: "create", status: status) }
        file = id
        // If this fails the file still survives an app crash; it just can't be synced.
        syncDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    }

    deinit { close() }

    func write(_ samples: UnsafeBufferPointer<Int16>) throws(Failure) {
        guard let file, let base = samples.baseAddress, !samples.isEmpty else { return }
        var count = UInt32(samples.count)
        let status = AudioFileWritePackets(file, false, count * 2, nil, packets, &count, base)
        guard status == noErr, Int(count) == samples.count else { throw Failure(step: "write", status: status) }
        packets += Int64(count)
    }

    /// F_FULLFSYNC (the drive flushes its cache), or fsync where unsupported.
    @discardableResult
    func fullSync() -> Bool {
        guard syncDescriptor >= 0 else { return false }
        return Self.fullSync(syncDescriptor)
    }

    /// Writes the real data size into the header, then makes it durable.
    /// Idempotent.
    func close() {
        if let file {
            AudioFileClose(file)
            self.file = nil
        }
        if syncDescriptor >= 0 {
            Self.fullSync(syncDescriptor)
            Darwin.close(syncDescriptor)
            syncDescriptor = -1
        }
    }

    @discardableResult
    static func fullSync(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }
}

