import AudioToolbox
import Foundation
import LexiconDomain

/// The file calls whose results the capture acts on, so a test can make them fail.
struct FileCalls: Sendable {
    var close: @Sendable (AudioFileID) -> OSStatus = { AudioFileClose($0) }
    /// F_FULLFSYNC, or fsync where unsupported: true when either worked.
    var sync: @Sendable (Int32) -> Bool = { CAFWriter.fullSync($0) }
    /// The floor lets the cheap read decide whether purgeable space needs a look.
    var freeBytes: @Sendable (URL, Int64) -> Int64? = { FreeSpace.availableBytes(at: $0, minimum: $1) }
}

/// One open `audio/<id>.caf` of 16 kHz mono Int16, written with
/// `AudioFileWritePackets` (synchronous: each call reaches the kernel, so an app
/// crash keeps every packet written). The data chunk's size stays -1 until
/// `close`, which the CAF spec defines as "read to the end of the file".
///
/// Banned here (crash test, #4): `ExtAudioFileWriteAsync` (lost whole
/// recordings), FLAC through ExtAudioFile (unreadable after a crash), and WAV
/// through AudioFile (reads back empty after a crash).
///
/// Created on the capture's caller, then confined to the writer queue.
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
    private let calls: FileCalls

    /// Never over an existing file: a second capture on one id fails here and
    /// goes RAM-only, so the first Dictation's audio is never erased.
    init(creating url: URL, calls: FileCalls = FileCalls()) throws(Failure) {
        self.calls = calls
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var format = Self.format
        var id: AudioFileID?
        let status = AudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, [], &id)
        guard status == noErr, let id else { throw Failure(step: "create", status: status) }
        file = id
        // If this fails the file still survives an app crash; it just can't be synced.
        syncDescriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    }

    deinit { try? close() }

    /// Makes and removes one CAF in the temporary folder, with no sync (it holds
    /// nothing). The first AudioFile call in a process loads AudioToolbox's file
    /// components; the capture's own create runs on fn-down's path, so that cost
    /// is paid here, at launch. True when the file was made.
    @discardableResult
    static func warmUp(in folder: URL = FileManager.default.temporaryDirectory) -> Bool {
        let url = folder.appending(path: "lexicon-warm-\(UUID().uuidString).caf")
        guard let writer = try? CAFWriter(creating: url, calls: FileCalls(sync: { _ in true })) else { return false }
        try? writer.close()
        try? FileManager.default.removeItem(at: url)
        return true
    }

    func write(_ samples: UnsafeBufferPointer<Int16>) throws(Failure) {
        guard let file, let base = samples.baseAddress, !samples.isEmpty else { return }
        var count = UInt32(samples.count)
        let status = AudioFileWritePackets(file, false, count * 2, nil, packets, &count, base)
        guard status == noErr, Int(count) == samples.count else { throw Failure(step: "write", status: status) }
        packets += Int64(count)
    }

    /// F_FULLFSYNC (the drive flushes its cache), or fsync where unsupported.
    /// Throws only when both fail. No descriptor is not a failure: the file still
    /// survives an app crash, it just can't be synced.
    func fullSync() throws(Failure) {
        guard syncDescriptor >= 0 else { return }
        guard calls.sync(syncDescriptor) else { throw Failure(step: "sync", status: errno) }
    }

    /// Writes the real data size into the header, then makes it durable.
    /// Releases both handles whatever fails, so it is idempotent; throws the
    /// first failure.
    func close() throws(Failure) {
        var failure: Failure?
        if let file {
            let status = calls.close(file)
            self.file = nil
            if status != noErr { failure = Failure(step: "close", status: status) }
        }
        if syncDescriptor >= 0 {
            if !calls.sync(syncDescriptor), failure == nil { failure = Failure(step: "sync", status: errno) }
            Darwin.close(syncDescriptor)
            syncDescriptor = -1
        }
        if let failure { throw failure }
    }

    @discardableResult
    static func fullSync(_ descriptor: Int32) -> Bool {
        fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
    }
}

