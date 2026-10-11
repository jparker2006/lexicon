#if DEBUG
/// One live mic capture, measured (#52). AudioCapture's probe fills it, the
/// test hooks carry it, `scripts/harness.sh hook capture` prints it. Debug
/// builds only.
public struct MicMeasurement: Codable, Sendable, Equatable {
    public var device: String?
    /// What fn-down actually got: "prepared" or "cold".
    public var engine: String
    /// fn-down to the first buffer.
    public var startGapMs: Int64?
    public var capturedMs: Int64
    /// RMS of the whole clip. About -90 or lower means the mic gave silence.
    public var levelDBFS: Double
    /// RMS of each 10 ms block in the last 300 ms, the tail included.
    public var lastBlocksDBFS: [Int]
    /// Audio kept after fn-up.
    public var tailMs: Int64
    /// The stop call to the Take: how long fn-up waits on the tail.
    public var stopMs: Int64
    /// The CAF read back. nil when there is no file (RAM only).
    public var fileMs: Int64?
    public var fileMatchesClip: Bool
    public var storage: String
    /// Audio missed per device change.
    public var deviceChangeGapsMs: [Int64]
    /// Halfway through: the control for the check below.
    public var micInUseWhileRecording: Bool
    /// 0.5 s after stop, any input device. The orange dot shows while one is in use.
    public var micInUseAfterStop: Bool
    /// Every input device as "name [uid]", to pick one with `device=<uid>`.
    public var inputs: [String]

    public init(device: String?, engine: String, startGapMs: Int64?, capturedMs: Int64, levelDBFS: Double,
                lastBlocksDBFS: [Int], tailMs: Int64, stopMs: Int64,
                fileMs: Int64?, fileMatchesClip: Bool, storage: String, deviceChangeGapsMs: [Int64],
                micInUseWhileRecording: Bool, micInUseAfterStop: Bool, inputs: [String]) {
        self.device = device
        self.engine = engine
        self.startGapMs = startGapMs
        self.capturedMs = capturedMs
        self.levelDBFS = levelDBFS
        self.lastBlocksDBFS = lastBlocksDBFS
        self.tailMs = tailMs
        self.stopMs = stopMs
        self.fileMs = fileMs
        self.fileMatchesClip = fileMatchesClip
        self.storage = storage
        self.deviceChangeGapsMs = deviceChangeGapsMs
        self.micInUseWhileRecording = micInUseWhileRecording
        self.micInUseAfterStop = micInUseAfterStop
        self.inputs = inputs
    }
}
#endif
