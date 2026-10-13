public import Foundation
public import LexiconDomain
import AVFAudio
import AudioToolbox

/// CAF format knowledge for files this module wrote. Used by History during
/// recovery and retry; History never parses audio itself.
public enum CAFFile {
    public enum State: Sendable, Hashable {
        /// Header says data size -1: the writer never closed it (crash or power loss).
        case open
        case closed
        /// No sample yet: zero bytes, a header with no data chunk, or a data chunk holding no sample.
        case empty
        /// Closed by the writer with no sample: what it leaves when the disk fails at the first
        /// write and the hold goes on in RAM, so the words may have existed.
        case closedEmpty
        /// The open failed for a reason other than "no such file" (EMFILE, EIO, a permission):
        /// the audio may be fine, so a later look may read it.
        case unavailable
        case unreadable
    }

    public enum Failure: Error, Sendable, Hashable {
        case unreadable(URL)
        /// Not 16 kHz mono 16-bit PCM.
        case wrongFormat(URL)
    }

    /// Reads the `data` chunk's size from the header. Never decodes audio.
    public static func state(of url: URL) -> State {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        // Only a missing file is known to be gone. Any other failure (EMFILE, EIO, a
        // permission) may pass, and the audio behind it may be whole.
        guard descriptor >= 0 else { return errno == ENOENT ? .unreadable : .unavailable }
        defer { close(descriptor) }
        return switch layout(descriptor) {
        case .unavailable: .unavailable
        case .notCAF: .unreadable
        case .noSample: .empty
        case .data(_, let size): size == -1 ? .open : .closed
        }
    }

    /// Writes the real data size into a crashed CAF's header, from the file's
    /// length (CAF spec: a -1 data chunk is last, and its length is "determined
    /// from the file size"). A torn last packet is cut off. Then F_FULLFSYNC, so
    /// the fixed header survives a power cut.
    ///
    /// Done by hand because AudioFile does not do it: reopening the file
    /// read-write and closing it leaves the size at -1 (measured, macOS 26).
    /// Idempotent: finalizing a closed file is a no-op. An empty file is left as
    /// it is: there is no sample to keep, and recovery deletes it.
    public static func finalize(_ url: URL) throws(Failure) {
        let descriptor = open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadable(url) }
        defer { close(descriptor) }
        let chunk: (offset: off_t, size: Int64)
        switch layout(descriptor) {
        case .unavailable, .notCAF: throw .unreadable(url)
        case .noSample: return
        case .data(let offset, let size): chunk = (offset, size)
        }
        guard chunk.size == -1 else { return }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(url) }
        let payload = info.st_size - chunk.offset - 12  // edit count (4 bytes) + audio
        let size = payload - (payload - 4) % 2  // whole 16-bit packets only
        if size != payload, ftruncate(descriptor, chunk.offset + 12 + size) != 0 { throw .unreadable(url) }
        let bigEndian = withUnsafeBytes(of: UInt64(size).bigEndian, Array.init)
        guard pwrite(descriptor, bigEndian, 8, chunk.offset + 4) == 8 else { throw .unreadable(url) }
        CAFWriter.fullSync(descriptor)
    }

    private enum Layout {
        /// A read failed: the bytes may be fine.
        case unavailable
        /// Not a CAF, or a damaged chunk header.
        case notCAF
        /// Nothing past the header yet: zero bytes, no data chunk, or a data chunk
        /// with no whole sample on disk. What a capture leaves when it dies before its
        /// first write. Not a file the writer closed with no sample: it closes one and
        /// goes on in RAM when the disk fails, so a closed file proves nothing was heard.
        case noSample
        /// The data chunk: where its header starts, and its size field (-1 while open).
        case data(offset: off_t, size: Int64)
    }

    /// Walks the chunk headers (big-endian) to `data`. A file the writer had not
    /// got past its header reads `.noSample`, so a crash then is not a damaged file;
    /// a chunk that claims more bytes than the file has is damaged.
    private static func layout(_ descriptor: Int32) -> Layout {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return .unavailable }
        let length = info.st_size
        guard length > 0 else { return .noSample }
        var header = [UInt8](repeating: 0, count: 12)
        guard pread(descriptor, &header, 8, 0) == 8 else { return length < 8 ? .notCAF : .unavailable }
        guard header[0..<4].elementsEqual("caff".utf8) else { return .notCAF }
        var offset: off_t = 8
        while offset + 12 <= length {
            guard pread(descriptor, &header, 12, offset) == 12 else { return .unavailable }
            let size = Int64(bitPattern: header[4..<12].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            if header[0..<4].elementsEqual("data".utf8) {
                guard size >= -1 else { return .notCAF }  // a damaged header
                // Edit count (4 bytes), then 16-bit samples. A closed chunk that says it holds
                // none is finished; one whose samples are not on disk was cut short.
                let onDisk = length - offset - 12
                let saysSamples = size == -1 || size - 4 >= 2
                return saysSamples && onDisk - 4 < 2 ? .noSample : .data(offset: offset, size: size)
            }
            guard size >= 0, size <= Int64.max - 12 - offset else { return .notCAF }  // a damaged header
            offset += 12 + size
        }
        return offset > length ? .notCAF : .noSample
    }

    /// Reads a 16 kHz mono Int16 CAF into RAM for retry, recovery and eval.
    /// Works on an open (-1) file too: it reads to the end of the file.
    public static func read(_ url: URL) throws(Failure) -> AudioClip {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        else { throw .unreadable(url) }
        let format = file.fileFormat.streamDescription.pointee
        guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == Double(PCM16k.sampleRate),
              format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16
        else { throw .wrongFormat(url) }
        // One read may return fewer frames than asked (measured: 38,912 of 40,000).
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)
        else { throw .unreadable(url) }
        var samples: [Int16] = []
        samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { throw .unreadable(url) }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        }
        return AudioClip(samples: samples)
    }
}
