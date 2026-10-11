# Research: crash-safe audio capture for Dictations

Checks the proposed design: while the user talks, write mic audio to disk about every 100 ms as 16 kHz mono 16-bit PCM in a CAF file, create a SQLite row when recording starts, keep audio 14 days or 1 GB rolling plus pinned files forever. Hard rule touched: "Never loses a dictation" ([grill record](../grill/2026-10-10-lexicon-grill.md), goal 5). Researched 2026-10-10 from primary sources: Apple's CAF spec, the macOS 15.5 SDK headers (AudioToolbox, AVFAudio), macOS man pages, Apple docs, WWDC transcripts, XNU source, SQLite docs, model cards and source code. Everything marked **measured** was run on Jake's M4 MacBook Air (Mac16,13, 16 GB, macOS 26.5.2, APFS internal SSD, on battery). The mic was never opened, so start latency is not measured yet; see [Measurements still to run](#measurements-still-to-run).

## Short answer

**Keep the core of the proposal. Change five things.**

Keep:
- **CAF, 16 kHz mono Int16, written every ~100 ms.** Verified: a CAF with data size `-1` is fully readable after `SIGKILL`, bit for bit, by `AVAudioFile`, `ExtAudioFile`, `afinfo` and `afconvert` (measured). The `-1` rule is in Apple's CAF spec. Stored size is 1.92 MB per minute, so 1 GB holds about 8.7 hours.
- **The SQLite row at start** and the 14 day / 1 GB window.

Change:
1. **Capture with `AVAudioEngine` plus an `AVAudioSinkNode`, not an input tap.** A tap delivers 100 to 400 ms buffers off the real-time thread. A sink node gets every ~10.7 ms I/O buffer on the real-time thread. The real-time block only copies into a lock-free ring. A writer queue drains it. Pin one input device per Dictation, default to the built-in mic, and never touch `outputNode` or `mainMixerNode`.
2. **Do not keep the mic open between Dictations, and do not pre-roll.** Either one means the orange privacy dot is on all the time and AirPods stay in low-quality call mode. Instead, call `prepare()` at launch and after every stop, start capture on key-down, and log each Dictation's start gap so clipping can be seen.
3. **Write with `AudioFileWritePackets` or synchronous `ExtAudioFileWrite`.** Never use `ExtAudioFileWriteAsync`: in the crash test it lost all 2 s of one recording and 0.9 s of another. Never record straight to FLAC through `ExtAudioFile`: after a crash the file could not be read at all.
4. **Flush policy:** `write()` every 100 ms (0.03 ms), `F_FULLFSYNC` every 1 s while recording (4 to 5 ms median, measured, on the writer queue), and `F_FULLFSYNC` at stop. Worst case: an app crash loses at most the ~100 ms still in the ring, and a kernel panic or power cut loses at most ~1 s. On next launch, recover any Dictation still marked recording and transcribe it.
5. **Convert sample rates with `AVAudioConverter` set to `MinimumPhase` at `.max` quality, not the default.** The default lets aliases through at only −31 dB and cuts 5 dB at 7 kHz. `MinimumPhase` is flat to 7 kHz with aliases at −163 dB. It costs 43 ms of CPU per minute of audio (measured), about 0.07% of one core.

Formats: keep 16 kHz. Every target model takes 16 kHz (Parakeet, Whisper). The mic's own rate changes when the device changes (48 kHz built-in, 16 or 24 kHz AirPods), and 48 kHz costs 3x the disk. Lossless FLAC saves about 35% (1.26 MB per minute) for 47 ms of CPU per minute, so it is worth adding later as an after-the-fact compaction step, not during capture. Do not store lossy audio: Opus or AAC would be 7 to 10 times smaller, but they risk WER and spoil the Test set.

## 1. Capture API

| API | What you get | Start and first audio | Fit for Lexicon |
|---|---|---|---|
| `AVAudioEngine` + input **tap** | `AVAudioPCMBuffer`s on an internal non-real-time thread. "Supported range is [100, 400] ms" per buffer [[AVAudioNode.h]](#src-avaudionode) | `prepare()` "preallocates many of the resources the engine requires... Use it to responsively start audio input" [[AVAudioEngine.h]](#src-avaudioengine) | Simplest, but 100+ ms granularity adds lag to streaming ASR and makes the tail at key release coarse |
| `AVAudioEngine` + **`AVAudioSinkNode`** (macOS 10.15+) | Raw `AudioBufferList` "on the realtime thread", at hardware format, no conversion [[AVAudioSinkNode.h]](#src-sinknode). Apple: use it when "installing a regular tap would not be sufficient because the tap doesn't operate in a real-time context" [[WWDC19-510]](#src-wwdc19) | Same engine start. Buffers at the device I/O size: 512 frames = 10.7 ms on the built-in mic (measured) | **Recommended.** Fine-grained, zero dependency, still gets engine conveniences (config-change notification, voice processing if ever wanted) |
| Core Audio **AUHAL** directly | Same as sink node, one layer lower. Input via `kAudioOutputUnitProperty_EnableIO` on element 1. AUHAL will not convert the sample rate: "the device's sample rate should match the desired sample rate" [[TN2091]](#src-tn2091) | Probably the fastest raw start, but not measured | Fallback only if measurement shows `AVAudioEngine` start is slow. More code, same result |
| `AVAudioRecorder` | Records to a file; you never see samples | n/a | **No.** You can't stream to ASR, and Apple points advanced recording to `AVAudioEngine` [[AVAudioRecorder]](#src-recorder) |
| Audio Queue Services | C API, buffers on a callback thread; can encode while recording [[AQS]](#src-aqs) | Similar | No advantage over the engine for this job |
| `AVCaptureSession` | Audio/video capture pipeline. `startRunning()` "is synchronous and blocks until the session starts" [[startRunning]](#src-startrunning) | Heavier, blocking start | **No.** It is built for camera work. The new AirPods high-quality recording option is iOS, iPadOS and Mac Catalyst 26 only, not native macOS [[bluetoothHighQualityRecording]](#src-bthq) |

Measured on the built-in mic, read-only (the mic was never opened): nominal 48 kHz, I/O buffer 512 frames (10.7 ms), device input latency 14 frames plus safety offset 36 frames, about 1 ms. Hardware latency is not the problem. Start-up time and Bluetooth are.

### Device changes and Bluetooth

- **AirPods mic means call mode.** On macOS, AirPods show up as two devices: an output device at 48 kHz and an input device at 16 kHz (24 kHz on later firmware). Opening the AirPods mic drops playback quality for as long as the mic is open [[Liscio]](#src-liscio) [[forum-693911]](#src-airpods24k). Wispr Flow's own docs mark AirPods "may be slow to start and have more errors in dictation" and label the built-in mic "(recommended)" [[Wispr-airpods]](#src-wispr-airpods) [[Wispr-firstwords]](#src-wispr-firstwords). Other dictation vendors' help pages put Bluetooth mic wake-up at about 0.5 to 2 s (for example [Voibe](https://www.getvoibe.com/help/airpods-bluetooth)). That number is not from Apple, so measure it.
- **Default to the built-in mic, even when AirPods are connected,** and let Jake pick another mic. This avoids the call-mode switch and keeps his music at full quality. The catch: in clamshell mode the built-in mic is gone ("A Mac's built-in mic cannot work with the lid closed" [[Wispr-firstwords]](#src-wispr-firstwords)), so fall back in a fixed order. Also note: Jake's Mac already lists `iPhone 13 (7) Microphone` (Continuity) as an input device (measured), which could become the system default without warning.
- **Pin the device for the whole Dictation.** Set the input device on the engine's input unit (`kAudioOutputUnitProperty_CurrentDevice` [[TN2091]](#src-tn2091)) rather than following the system default mid-sentence.
- **Never touch `outputNode` or `mainMixerNode`.** On macOS, touching either one makes `AVAudioEngine` build an aggregate device from input and output, which is what pulls AirPods into call mode even for playback [[Liscio]](#src-liscio).
- **Expect the engine to stop itself.** When input hardware changes channel count or sample rate, "the engine stops itself... and issues this notification" (`AVAudioEngineConfigurationChangeNotification`). Input chains "must follow the hardware sample rate" [[AVAudioEngine.h]](#src-avaudioengine). On that notification: rebuild the engine (developers report a fresh engine is the only reliable fix after a route change [[forum-658078]](#src-forum-658078)), reconnect at the new rate, rebuild the converter, and keep writing to the **same 16 kHz file**. Record the gap in the row. A fixed stored rate is what makes this seamless.
- **Voice processing off by default.** It ducks other apps' audio [[WWDC23-10235]](#src-wwdc23), and ASR models are trained on plain audio. Worth one A/B on the Test set later.

### Pre-warming and pre-roll

- Keeping the engine running between Dictations keeps the mic open. That means the orange dot is always on ("An orange dot next to the Control Center icon... indicates the microphone on your Mac is in use" [[Apple-CC]](#src-orange)), and if AirPods are the input they stay in call mode. Apple itself advises: "To conserve power, it is advised that the client pause/stop the engine when not in use" [[AVAudioEngine.h]](#src-avaudioengine). **Verdict: no always-on mic.**
- Pre-roll (keeping the last N ms before the key press) needs the mic open all the time, so **no pre-roll**.
- What to do instead (all free):
  1. `prepare()` at launch and after every stop, so `start()` only has to start the hardware.
  2. Start capture on the hotkey's **key-down**, before any hold threshold. If it turns out to be a tap, throw it away.
  3. Optional linger: leave the engine running 2 to 3 s after a Dictation for quick back-to-back Dictations. Cost: the orange dot stays on that long.
  4. Show the "listening" cue when the **first buffer arrives**, not on key-down. That turns Wispr's "wait a moment after pressing the hotkey" into a signal Jake can see.
  5. Log `firstSampleHostTime − keyDownHostTime` on every Dictation row. Clipping becomes a number, not a feeling.
- At key release, keep capturing a short tail (~150 to 250 ms) before stopping so the last word is never cut off. With a sink node the stop granularity is ~11 ms; with a tap it is a 100+ ms buffer.

## 2. Writing safely

### The pattern

- **Real-time thread (sink node block):** copy the buffer into a preallocated single-producer, single-consumer lock-free ring, nothing else. Apple: no "memory allocations, call to lib dispatch, or blocking on a mutex" [[WWDC19-510]](#src-wwdc19). Build the ring on Swift's `Synchronization.Atomic` (macOS 15+) [[Atomic]](#src-atomic), with no package. 2 s of 48 kHz Float32 mono is 384 KB.
- **Writer: one serial queue, timer every 100 ms.** Drain the ring, convert to 16 kHz Int16, write the packets, and append to the in-RAM copy the ASR uses. Measured costs per 100 ms: SRC about 0.07 ms, `write()` 0.03 ms median. A plain `write()` peaked at 7 ms in one run (measured), which is exactly why it must never run on the real-time thread.
- **RAM is the primary copy, disk is the backup.** The whole Dictation sits in RAM anyway for transcription (1.92 MB per minute at 16 kHz Int16). If the disk fails, keep going in RAM, finish the Dictation, and warn.

### Which write API: measured crash test

Each API wrote 16 kHz Int16 audio in 100 ms chunks for 5 s (and in a second run, 2 s). Then the process killed itself with `SIGKILL`, with no close and no flush. Then the file was read back.

| Writer | Header after kill | Readable after kill (5 s run) |
|---|---|---|
| `AudioFileWritePackets`, CAF, default settings | data size `-1` | **All 80,000 frames, bit exact** |
| `ExtAudioFileWrite` (sync), CAF | data size `-1` | **All, bit exact** |
| `AVAudioFile`, CAF | real size, updated on every write | All, bit exact |
| `AVAudioFile`, WAV | RIFF and data sizes correct | All, bit exact |
| `AudioFileWritePackets`, WAV, default settings | data size `0` | **Nothing** (`AVAudioFile`, `ExtAudioFile`, `afinfo` all see 0 frames) |
| `AudioFileWritePackets`, WAV, `DeferSizeUpdates = 0` | correct | All |
| `ExtAudioFileWriteAsync`, CAF | `-1` | **Lost the tail:** 65,536 of 80,000 frames (0.9 s gone). In the 2 s run, **everything was lost** (header only) |
| `ExtAudioFileWrite`, FLAC in CAF | `-1`, no packet table | **Unreadable** (`afconvert` fails, error −66567) |
| `AVAudioFile`, FLAC or ALAC in CAF | sizes and packet table current | All, bit exact |

What the sources say:
- **CAF `-1` is a documented contract.** "An `mChunkSize` value of `-1` indicates that the size of the data section for this chunk is unknown. In this case, the Audio Data chunk must appear last in the file" [[CAF spec]](#src-caf). So **never add a chunk after `data` while recording.** Keep metadata in SQLite.
- **`AudioFile` defers header updates by default:** "This is more efficient, but less safe since, if the application crashes before the size is updated, the file may not be readable. The default value is one" [[AudioFile.h]](#src-audiofile). For CAF this is harmless because of `-1`. For WAV it gives a file Apple's APIs read as empty, as the test shows. (Repairing it means rewriting two 4-byte fields from the file length, which is trivial but is custom code.)
- **`ExtAudioFileWriteAsync`:** "Pending writes are not guaranteed to be flushed to disk until ExtAudioFileDispose is called" [[ExtendedAudioFile.h]](#src-extaudiofile). The test confirms it.
- **`AVAudioFile` updating the header on every write is undocumented.** The header only says that `close` exists "to achieve specific control over when the file's header is updated" [[AVAudioFile.h]](#src-avaudiofile). Don't rely on it. Use the documented CAF `-1` path.
- **CAF vs WAV:** CAF wins because it has a written rule for crashes. WAV only survives if every write also rewrites the header.
- **Recovery cost:** reopening a crashed CAF read-write and closing it writes the real size back (as the spec asks readers to do). That took **1.5 ms** (measured).

## 3. Durability

| Failure | What survives without any sync | Source |
|---|---|---|
| **App crash** | Everything already passed to `write()`. It is in the kernel page cache, which does not belong to the app. The crash test above is exactly this case. | measured; SQLite: "Transactions are durable across application crashes regardless of the synchronous setting" [[SQLite]](#src-sqlite) |
| **Sleep or lid close** | The kernel syncs file systems before sleep ("An in-kernel sync for power management to call") [[XNU]](#src-xnu). `NSWorkspace.willSleepNotification` lets the app delay sleep "for up to 30 seconds" [[willSleep]](#src-willsleep) | |
| **Kernel panic, forced power-off, dead battery** | Only what reached stable storage. `fsync` moves data to the drive, but "the drive itself may not physically write the data... for quite some time." `F_FULLFSYNC` "asks the drive to flush all buffered data to permanent storage" [[fsync(2)]](#src-fsync) [[fcntl(2)]](#src-fcntl) | |

Measured on this Mac, 3,200-byte appends (100 ms of audio), 300 samples each, two runs:

| Policy | Median | p95 | Max |
|---|---|---|---|
| `write()` only | 0.03 ms | 0.06 to 0.12 ms | 0.3 to 7 ms |
| `fsync` | 0.10 to 0.15 ms | 0.2 to 0.4 ms | 4 to 11 ms |
| `F_BARRIERFSYNC` (ordering only, "durability is not" promised [[fcntl(2)]](#src-fcntl)) | 0.54 to 0.70 ms | 1.1 to 1.3 ms | 11 to 29 ms |
| `F_FULLFSYNC` | **4.1 to 5.2 ms** | 6.4 to 7.5 ms | 12 to 19 ms |

For context, in 2022 Hector Martin found Apple SSDs "more than 3 times slower than a lowly SATA SSD at flushing its cache" [[mjtsai]](#src-mjtsai). On this M4 Air a full flush is still only ~5 ms, so it is affordable once per second. It is not affordable on every 100 ms chunk if a cheaper option is good enough.

**Recommended flush policy:**
- Every 100 ms: `write()` only.
- Every 1 s while recording: `fcntl(fd, F_FULLFSYNC)` on the writer queue. That is ~5 ms per second, mostly waiting on the SSD rather than using CPU, on a thread no one waits for. If it fails (some external drives don't support it), fall back to `fsync`, as SQLite does [[SQLite]](#src-sqlite).
- At stop: `F_FULLFSYNC`, close (which writes the real size), then commit the row. Run this in parallel with transcription, never in front of text insertion.
- On `willSleepNotification`: stop the Dictation, flush, and finalize. Don't auto-resume on wake.
- On launch: every row still in `recording` gets its file finalized (1.5 ms) and is queued for transcription. Every audio file without a row gets a row. **The file on disk is the source of truth; the row points at it.** SQLite in WAL mode with `synchronous=NORMAL` is enough for the row, since it survives app crashes and stays consistent after power loss [[SQLite]](#src-sqlite).

Worst case: app crash loses ≤ ~100 ms (whatever is still in the ring), kernel panic or power cut loses ≤ ~1 s. The Dictation itself is always recoverable.

## 4. Format and size

All sizes and CPU numbers are **measured**: a 50.7 s spoken paragraph from macOS `say` (full of tech words), encoded with AudioToolbox in-process in 100 ms chunks. Synthetic speech is cleaner than a real mic, so the lossless rows also show a version with a mic-like noise floor added. "CPU" is CPU time per minute of audio.

| Format | Size per minute | 1 GB holds | CPU per minute of audio |
|---|---|---|---|
| **PCM Int16, 16 kHz (proposal)** | **1.92 MB** | **8.7 h** | ~0 (4 ms to write) |
| PCM Int16, 48 kHz | 5.76 MB | 2.9 h | ~0 |
| FLAC, 16 kHz (clean / −60 dBFS noise / −50 dBFS noise) | 1.14 / 1.26 / 1.33 MB | 13.2 h at 1.26 | 47 ms |
| ALAC, 16 kHz (same three) | 1.14 / 1.27 / 1.33 MB | 13.1 h | 32 ms |
| FLAC, 48 kHz (clean) | 2.49 MB | 6.7 h | not measured in-process |
| AAC-LC 32 kbps, 16 kHz | 0.26 to 0.28 MB | ~62 h | 77 ms |
| Opus 24 kbps, 16 kHz (in CAF) | 0.18 to 0.22 MB | ~80 h | 713 ms |

**16 kHz, not 48 kHz.**
- The models take 16 kHz. Parakeet TDT 0.6B v3: "16kHz Audio", "Monochannel audio" [[Parakeet]](#src-parakeet). Whisper's loader resamples everything to `SAMPLE_RATE = 16000` [[Whisper]](#src-whisper). OpenAI's realtime transcription example sends 24 kHz PCM [[OpenAI-RT]](#src-openai), but turning 16 kHz into 24 kHz is a lossless resample that adds no information.
- The mic's rate is not stable within one Dictation (48 kHz built-in, 16 or 24 kHz AirPods). A fixed stored rate lets one file outlive a device switch.
- 48 kHz triples the disk and cuts the window from 8.7 h to 2.9 h per GB, for content above 8 kHz that today's ASR throws away.
- The one argument for more is a future model that uses 8 to 12 kHz content. That is speculative. If it happens, change the rate for new Dictations then.

**Lossless (FLAC or ALAC): yes later, as compaction, not during capture.** It saves ~35% for under 0.1% of a core. But direct FLAC capture through `ExtAudioFile` was unreadable after a crash (above). If Jake dictates enough that the 1 GB cap starts deleting audio before 14 days, add a background step: after a Dictation is transcribed, encode FLAC-in-CAF to a temp file, `F_FULLFSYNC`, rename over the original, update the row. Pick FLAC over ALAC because Python, ffmpeg and others can read it, which matters for Test set tools. It costs 15 ms more per minute of audio.

**Lossy: no, for stored audio.** The evidence is thin and mixed. An Amazon study found "the WER degrades by 12.6% relative with 16kpbs [Opus] as compared to uncompressed audio" (not Whisper-era models) [[Khare 2020]](#src-khare). A 2026 paper on Whisper large-v3 with Polish medical terms says "AAC, MP3, Opus, and ADPCM cause no statistically significant degradation". Only the abstract was available, so the bitrates are unknown [[Zaporowski 2026]](#src-zaporowski). The deciding reason is the Test set: it exists to compare models on Jake's voice, and lossy storage would bake codec damage into every comparison. Apple's Opus encoder is also slow here (713 ms per minute of audio).

**Side note, separate decision:** the format used for *upload* to a cloud model is a separate decision. One minute of PCM is 2.6 MB as base64, and on a slow uplink that is real lag. FLAC upload is 35% smaller for under 1 ms per second of audio. Worth checking in the lag work.

## 5. What the proposal misses

- **Sample-rate conversion quality (measured).** For 48 → 16 kHz with `AVAudioConverter`, by algorithm and quality: 4 / 7 / 7.6 kHz tone gain, aliased 10 kHz tone, CPU per minute of audio:

  | Setting | 4 kHz | 7 kHz | 7.6 kHz | Alias at 10 kHz | CPU per minute |
  |---|---|---|---|---|---|
  | Default (`Normal`, quality 64) | −0.1 dB | −5.2 dB | −8.0 dB | **−31 dB** | 10 to 14 ms |
  | `Normal`, `.max` | 0.0 | −3.9 | −12.7 | −114 dB | 18 to 20 ms |
  | **`MinimumPhase`, `.max`** | −0.1 | **−0.1** | −79 | **−163 dB** | **43 ms** |
  | `Mastering`, `.max` | 0.0 | 0.0 | 0.0 | −155 dB | 580 ms |

  Use `MinimumPhase` + `.max`. It keeps sibilants up to 7 kHz, removes aliasing, and has the low delay that suits streaming. Defaults confirmed in `AVAudioConverter.h` and at runtime [[AVAudioConverter.h]](#src-converter).
- **Mic permission.** Without permission the app "captures only silence (zeroed out audio samples)", not an error [[requestRecordPermission]](#src-perm). On macOS the app needs `NSMicrophoneUsageDescription` **and** the `com.apple.security.device.audio-input` entitlement, or "the system terminates your app" [[authorization]](#src-auth). A sandboxed app missing the entitlement got all-zero buffers and repeated prompts [[forum-771048]](#src-forum-771048). So: check `AVCaptureDevice.authorizationStatus(for: .audio)` before start, and watch for **exactly zero** samples in the first ~300 ms. Warn right away instead of producing an empty Dictation. Zero-filled taps with no error have also been reported in other device states [[forum-836510]](#src-forum-836510).
- **AirPods stem mute.** On macOS 14+, a Bluetooth gesture can mute input, and the app is told through `AVAudioApplication.setInputMuteStateChangeHandler` [[inputMute]](#src-mute). Treat muted as a visible state, not silence.
- **Disk full.** Jake's data volume has 24 GB free of 460 GB (95% used, measured). Check `volumeAvailableCapacityForImportantUsageKey` at start [[capacity]](#src-capacity). Declare it in `PrivacyInfo.xcprivacy`, since it is a required-reason API. On `ENOSPC` or any write error, keep the Dictation in RAM, transcribe it, and show a warning. Never fail the Dictation because of the disk.
- **Where the files live.** Use `~/Library/Application Support/<bundle id>/Audio/`, not `Caches`: "Apps should never rely on the existence of cache files" [[FS guide]](#src-fsguide). Name files by UUID. Consider excluding them from Time Machine (privacy and size).
- **Retention rules that protect the hard rule:**
  - Evict only audio whose Dictation finished transcription. Never evict a Dictation in `recording` or `failed` state.
  - Evict oldest unpinned first.
  - Count pinned files separately from the 1 GB, so pins can't starve the rolling window.
  - Deletion can't be undone, so do it in one place, after the row update commits.
- **Don't block the hot path.** Create the CAF file and insert the row on the writer queue after the mic has started, not before. Better still, keep the next file pre-created and open while idle, and clean up an unused empty file on launch.
- **No new dependencies or binary size.** Everything above is AVFAudio, AudioToolbox, Foundation and Synchronization, all part of the OS.

## Recommended design

```
key-down ─▶ engine.start()  (prepared at launch; device pinned, default built-in mic)
            AVAudioInputNode ─▶ AVAudioSinkNode  [real-time, ~10.7 ms buffers, hardware format]
                                   │ memcpy only
                                   ▼
                     SPSC lock-free ring (2 s, 384 KB, Synchronization.Atomic)
                                   │ writer serial queue, every 100 ms
                                   ▼
            AVAudioConverter (MinimumPhase, .max) ─▶ 16 kHz mono Int16
                 ├─▶ in-RAM PCM for ASR (1.92 MB/min)
                 └─▶ AudioFileWritePackets ─▶ <uuid>.caf  (data size -1 while open)
                        F_FULLFSYNC every 1 s; F_FULLFSYNC + close at stop
SQLite (WAL, synchronous=NORMAL): row created by writer queue after first buffer;
   holds file path, state (recording/transcribing/done/failed), start gap ms, device, gaps.
Launch: finalize + transcribe any `recording` rows; adopt orphan files.
Config change: rebuild engine at new hardware rate, same file continues, gap logged.
```

Key numbers (measured, M4 Air):
- Write per 100 ms chunk: 0.03 ms.
- SRC: 43 ms per minute of audio.
- `F_FULLFSYNC`: 4 to 5 ms median, once per second.
- Recovery of a crashed file: 1.5 ms.
- Storage: 1.92 MB per minute, 8.7 h per GB (13 h with FLAC compaction).
- RAM: ring 384 KB plus 1.92 MB per minute of the current Dictation.
- Added binary size: 0 MB.

## Measurements still to run

These need the mic open, so they were not run without Jake's say-so. Run them in the first capture prototype:
1. **Start gap:** key-down host time → first sink-node buffer `mHostTime`, for a cold `start()`, a `start()` after `prepare()`, and a lingering engine. Do it for the built-in mic and for AirPods (the call-mode switch). This decides whether the linger option or a raw AUHAL path is worth it.
2. **CPU and energy of an open, idle engine** (Activity Monitor energy impact over 10 minutes), to price the linger option.
3. **Tap vs sink node at stop:** confirm how much audio a tap drops when the engine stops mid-buffer.
4. **FLAC ratio on Jake's real voice and room,** to replace the synthetic-speech estimate above.

## Sources

- <a id="src-caf"></a>[CAF spec] Apple, *Core Audio Format Specification*, Audio Data Chunk. https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html
- <a id="src-audiofile"></a>[AudioFile.h] macOS 15.5 SDK, `AudioToolbox/AudioFile.h`, `kAudioFilePropertyDeferSizeUpdates`.
- <a id="src-extaudiofile"></a>[ExtendedAudioFile.h] macOS 15.5 SDK, `AudioToolbox/ExtendedAudioFile.h`, `ExtAudioFileWriteAsync`.
- <a id="src-avaudiofile"></a>[AVAudioFile.h] macOS 15.5 SDK, `AVFAudio/AVAudioFile.h`, `close`.
- <a id="src-avaudionode"></a>[AVAudioNode.h] macOS 15.5 SDK, `AVFAudio/AVAudioNode.h`, `installTapOnBus:bufferSize:format:block:`.
- <a id="src-avaudioengine"></a>[AVAudioEngine.h] macOS 15.5 SDK, `AVFAudio/AVAudioEngine.h`: `prepare`, `autoShutdownEnabled`, `AVAudioEngineConfigurationChangeNotification`.
- <a id="src-sinknode"></a>[AVAudioSinkNode.h] macOS 15.5 SDK, `AVFAudio/AVAudioSinkNode.h`.
- <a id="src-converter"></a>[AVAudioConverter.h] macOS 15.5 SDK, `AVFAudio/AVAudioConverter.h` and `AVAudioSettings.h`.
- <a id="src-wwdc19"></a>[WWDC19-510] Apple, *What's New in AVAudioEngine*. https://developer.apple.com/videos/play/wwdc2019/510/
- <a id="src-wwdc23"></a>[WWDC23-10235] Apple, *What's new in voice processing*. https://developer.apple.com/videos/play/wwdc2023/10235/
- <a id="src-tn2091"></a>[TN2091] Apple, *Device input using the HAL Output Audio Unit*. https://developer.apple.com/library/archive/technotes/tn2091/_index.html
- <a id="src-recorder"></a>[AVAudioRecorder] https://developer.apple.com/documentation/avfaudio/avaudiorecorder
- <a id="src-aqs"></a>[AQS] Audio Queue Services. https://developer.apple.com/documentation/audiotoolbox/audio-queue-services
- <a id="src-startrunning"></a>[startRunning] https://developer.apple.com/documentation/avfoundation/avcapturesession/startrunning()
- <a id="src-bthq"></a>[bluetoothHighQualityRecording] availability iOS / iPadOS / Mac Catalyst 26.0 (doc JSON). https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording ; WWDC25 *Enhance your app's audio recording capabilities*, https://developer.apple.com/videos/play/wwdc2025/251/
- <a id="src-perm"></a>[requestRecordPermission] https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)
- <a id="src-auth"></a>[authorization] Apple, *Requesting authorization to capture and save media*. https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media
- <a id="src-mute"></a>[inputMute] https://developer.apple.com/documentation/avfaudio/avaudioapplication/setinputmutestatechangehandler(_:)
- <a id="src-capacity"></a>[capacity] https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey
- <a id="src-willsleep"></a>[willSleep] https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification
- <a id="src-atomic"></a>[Atomic] https://developer.apple.com/documentation/synchronization/atomic
- <a id="src-fsguide"></a>[FS guide] Apple, *File System Programming Guide*, macOS Library directory details. https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html
- <a id="src-orange"></a>[Apple-CC] Apple, *Use Control Center on Mac*. https://support.apple.com/guide/mac-help/mchl50f94f8f/mac
- <a id="src-fsync"></a>[fsync(2)] macOS man page, `man 2 fsync`.
- <a id="src-fcntl"></a>[fcntl(2)] macOS man page, `man 2 fcntl`: `F_FULLFSYNC`, `F_BARRIERFSYNC`.
- <a id="src-xnu"></a>[XNU] `bsd/vfs/vfs_syscalls.c`, `sync_internal`. https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c
- <a id="src-sqlite"></a>[SQLite] *Pragma statements*: `synchronous`, `fullfsync`. https://www.sqlite.org/pragma.html
- <a id="src-mjtsai"></a>[mjtsai] M. Tsai, *Apple SSD Benchmarks and F_FULLSYNC* (collects Hector Martin's measurements), 2022. https://mjtsai.com/blog/2022/02/17/apple-ssd-benchmarks-and-f_fullsync/
- <a id="src-liscio"></a>[Liscio] C. Liscio (Capo developer), *More on AVAudioEngine + AirPods*, 2021. https://supermegaultragroovy.com/2021/01/28/more-on-avaudioengine-airpods/
- <a id="src-airpods24k"></a>[forum-693911] Apple Developer Forums, AirPods input rate 16 kHz → 24 kHz after firmware 4A400. https://developer.apple.com/forums/thread/693911
- <a id="src-forum-658078"></a>[forum-658078] Apple Developer Forums, AVAudioEngine after AirPods route change. https://developer.apple.com/forums/thread/658078
- <a id="src-forum-771048"></a>[forum-771048] Apple Developer Forums, all-zero input, missing audio-input entitlement (DTS reply). https://developer.apple.com/forums/thread/771048
- <a id="src-forum-836510"></a>[forum-836510] Apple Developer Forums, tap delivers all-zero buffers with no error. https://developer.apple.com/forums/thread/836510
- <a id="src-wispr-airpods"></a>[Wispr-airpods] Wispr Flow docs, *Troubleshooting audio playback & AirPod issues*. https://docs.wisprflow.ai/articles/8533503284-knwon-audio-playback-airpod-issues-ios-macos
- <a id="src-wispr-firstwords"></a>[Wispr-firstwords] Wispr Flow docs, *Missing first words in transcriptions*. https://docs.wisprflow.ai/articles/3566082841-fix-missing-first-words-in-transcriptions
- <a id="src-parakeet"></a>[Parakeet] NVIDIA, *parakeet-tdt-0.6b-v3* model card. https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- <a id="src-whisper"></a>[Whisper] OpenAI, `whisper/audio.py`. https://github.com/openai/whisper/blob/main/whisper/audio.py
- <a id="src-openai"></a>[OpenAI-RT] OpenAI, *Realtime transcription*. https://developers.openai.com/api/docs/guides/realtime-transcription
- <a id="src-khare"></a>[Khare 2020] Khare, Sundaram, Wu, *Multi-channel Acoustic Modeling using Mixed Bitrate OPUS Compression*. https://arxiv.org/abs/2002.00122
- <a id="src-zaporowski"></a>[Zaporowski 2026] Zaporowski, Kurowski, *Analysis of the Efficiency of Polish Medical Terminology Recognition by Whisper ASR System Depending on the Selected Audio Codecs*, ISD 2026 (abstract). https://aisel.aisnet.org/isd2014/proceedings2026/datascience/13

### How the measurements were made

Small Swift command-line programs built with `swiftc -O` (Swift 6.1.2) on the M4 Air:
- **Crash test:** one writer per API, 100 ms chunks of a 440 Hz tone, then `kill(getpid(), SIGKILL)`. Then inspect the header bytes, then read back with `AVAudioFile`, `ExtAudioFile`, `afinfo` and `afconvert`, and compare samples to the expected tone.
- **Sync benchmark:** 300 appends of 3,200 bytes, 20 ms apart, under each sync call, on the internal APFS data volume.
- **Codecs:** `ExtAudioFile` in-process, CPU from `getrusage`. Noise variants add Gaussian noise at −70, −60 and −50 dBFS RMS.
- **SRC:** `AVAudioConverter` with 4,800-frame (100 ms) input chunks. Quality from single tones at −6 dBFS, 1 s, with edges trimmed.
- **Device facts:** read-only Core Audio property queries. No device was opened.
