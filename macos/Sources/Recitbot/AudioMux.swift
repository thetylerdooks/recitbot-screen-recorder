import AVFoundation
import CoreMedia
import RecitbotCore

/// One pass over the finished capture: the silent video from `trim` (a keyframe, so the stream copy starts exactly there)
/// with the mixed AAC track (128 kb/s, 48 kHz stereo, padded or cut to the video: apad + -shortest), and with a mic the
/// 16 kHz mono transcription WAV (the mic alone, muted spans silent; the mix's own length). No mic = no WAV is written
/// (any old file at outWav is removed). parity: WindowsFfmpegBackend.MixAudio + AudioMath.MixFilter
enum AudioMux {
    static func run(video: String, videoSeconds: Double, trim: CMTime, plan: MixPlan, micWav: String?, sysWav: String?,
                    outVideo: String, outWav: String) throws {
        // The whole mix within 180 s (C#: the mix ffmpeg's WaitForExit(180000), then "audio mix timed out").
        let deadline = Date().addingTimeInterval(180)
        func left() -> Double { return max(0, deadline.timeIntervalSinceNow) }
        let mixer: AudioMixer
        do { mixer = try AudioMixer(plan: plan, micWav: micWav, sysWav: sysWav) } catch { throw CaptureError("audio mix failed (" + Agent.message(error) + ")") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: video))
        let loaded = Event(), tracks = Box<[AVAssetTrack]>()
        asset.loadTracks(withMediaType: .video) { t, _ in tracks.value = t; loaded.set() }
        if !loaded.wait(min(30, left())) { throw CaptureError("audio mix timed out") }
        guard let track = tracks.value?.first else { throw CaptureError("audio mix failed (no video track)") }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw CaptureError("audio mix failed (" + Agent.message(error) + ")") }
        let vout = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        vout.alwaysCopiesSampleData = false
        reader.add(vout)
        reader.timeRange = CMTimeRange(start: trim, duration: .positiveInfinity)
        guard reader.startReading() else {
            throw CaptureError("audio mix failed (" + (reader.error.map { Agent.message($0) } ?? "video not readable") + ")")
        }
        // The reader can open with marker buffers: no samples, no format description, only an EditBoundary attachment
        // (macOS 27 does this for every passthrough read of our capture MP4). A nil sourceFormatHint makes the MP4 writer
        // refuse the passthrough video input, so the hint and the session start come from the first real frame.
        var firstFrame: CMSampleBuffer?, markers = 0
        while let sb = vout.copyNextSampleBuffer() {
            if AudioMux.isFrame(sb) { firstFrame = sb; break }
            markers += 1
        }
        guard let first = firstFrame, let hint = CMSampleBufferGetFormatDescription(first) else {
            throw CaptureError("audio mix failed (" + (reader.error.map { Agent.message($0) } ?? "no video frames") + ")")
        }
        if markers > 0 { Log.write("audio mix: skipped " + String(markers) + " empty marker buffer(s) before the first frame") }

        try? FileManager.default.removeItem(atPath: outVideo)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: outVideo), fileType: .mp4) } catch {
            throw CaptureError("audio mix failed (" + Agent.message(error) + ")")
        }
        writer.shouldOptimizeForNetworkUse = true
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        vin.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin) else { throw inputError(writer, "video passthrough " + AudioMux.describe(hint)) }
        writer.add(vin)
        let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioMux.aacSettings)
        ain.expectsMediaDataInRealTime = false
        guard writer.canAdd(ain) else { throw inputError(writer, "audio AAC " + String(AudioMixer.rate) + " Hz 2 ch 128 kb/s") }
        writer.add(ain)
        guard writer.startWriting() else { throw CaptureError("audio mix failed (" + (writer.error.map { Agent.message($0) } ?? "writer") + ")") }
        let start = CMSampleBufferGetPresentationTimeStamp(first)
        writer.startSession(atSourceTime: start)

        guard let format = pcmFormat() else { throw CaptureError("audio mix failed (pcm format)") }
        var wav: WavWriter? = nil
        if mixer.transcribes {
            do { wav = try WavWriter(path: outWav, rate: 16000, channels: 1) } catch { throw CaptureError("audio mix failed (" + Agent.message(error) + ")") }
        } else {
            try? FileManager.default.removeItem(atPath: outWav)
        }
        let audioFrames = Int64(max(0, (videoSeconds - CMTimeGetSeconds(trim)) * Double(AudioMixer.rate)).rounded())
        let st = MuxState(reader: reader, vout: vout, writer: writer, vin: vin, ain: ain, mixer: mixer, wav: wav, first: first, start: start,
                          format: format, audioFrames: audioFrames)
        st.pump()
        if st.group.wait(timeout: .now() + left()) == .timedOut {
            writer.cancelWriting()
            reader.cancelReading()
            throw CaptureError("audio mix timed out")
        }
        st.drainTranscription()
        if reader.status == .reading { reader.cancelReading() }
        if let f = st.failure {
            writer.cancelWriting()
            throw CaptureError("audio mix failed (" + f + ")")
        }
        let done = Event()
        writer.finishWriting { done.set() }
        if !done.wait(left()) { throw CaptureError("audio mix timed out") }
        if writer.status != .completed {
            throw CaptureError("audio mix failed (" + (writer.error.map { Agent.message($0) } ?? "not completed") + ")")
        }
    }

    /// 128 kb/s AAC, 48 kHz stereo (explicit stereo layout).
    static var aacSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: AudioMixer.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
    }

    /// A buffer that carries media (not an empty marker/edit-boundary buffer).
    static func isFrame(_ sb: CMSampleBuffer) -> Bool {
        return CMSampleBufferGetNumSamples(sb) > 0 && CMSampleBufferGetFormatDescription(sb) != nil
    }

    /// "avc1 1726x1080" for a video format description.
    static func describe(_ fd: CMFormatDescription) -> String {
        let t = CMFormatDescriptionGetMediaSubType(fd)
        let cc = String(bytes: [24, 16, 8, 0].map { UInt8((t >> $0) & 0xFF) }, encoding: .ascii) ?? String(t)
        let d = CMVideoFormatDescriptionGetDimensions(fd)
        return cc + " " + String(d.width) + "x" + String(d.height)
    }

    /// Which writer input was refused and why (writer.error when it has one); the full line also goes to the log.
    static func inputError(_ writer: AVAssetWriter, _ what: String) -> CaptureError {
        let why = writer.error.map { Agent.message($0) } ?? "not accepted by the mp4 writer"
        Log.write("audio mix: writer cannot add " + what + ": " + why + " (writer status " + String(writer.status.rawValue) + ")")
        return CaptureError("audio mix failed (" + what + ": " + why + ")")
    }

    /// The two pull loops (video stream copy, mixed audio) and what they share. Each loop runs on its own serial queue.
    final class MuxState: @unchecked Sendable {
        let reader: AVAssetReader, vout: AVAssetReaderTrackOutput, writer: AVAssetWriter
        let vin: AVAssetWriterInput, ain: AVAssetWriterInput
        let mixer: AudioMixer, wav: WavWriter?, down = Downsampler16k()
        let start: CMTime, format: CMAudioFormatDescription, audioFrames: Int64
        let group = DispatchGroup()
        let vq = DispatchQueue(label: "com.recitbot.mux.video"), aq = DispatchQueue(label: "com.recitbot.mux.audio")
        private let gate = NSLock()
        private var failed: String?
        private var pending: CMSampleBuffer?
        private var written: Int64 = 0
        private var mixDone = false
        private var videoOpen = true, audioOpen = true

        init(reader: AVAssetReader, vout: AVAssetReaderTrackOutput, writer: AVAssetWriter, vin: AVAssetWriterInput, ain: AVAssetWriterInput,
             mixer: AudioMixer, wav: WavWriter?, first: CMSampleBuffer, start: CMTime, format: CMAudioFormatDescription, audioFrames: Int64) {
            self.reader = reader; self.vout = vout; self.writer = writer; self.vin = vin; self.ain = ain
            self.mixer = mixer; self.wav = wav; pending = first; self.start = start; self.format = format; self.audioFrames = audioFrames
        }

        var failure: String? { gate.lock(); defer { gate.unlock() }; return failed }

        func fail(_ why: String) { gate.lock(); if failed == nil { failed = why }; gate.unlock() }

        func pump() {
            group.enter()
            group.enter()
            vin.requestMediaDataWhenReady(on: vq) { self.videoStep() }
            ain.requestMediaDataWhenReady(on: aq) { self.audioStep() }
        }

        /// On vq.
        private func videoStep() {
            while videoOpen && vin.isReadyForMoreMediaData {
                guard let sb = pending ?? vout.copyNextSampleBuffer() else { closeVideo(); return }
                pending = nil
                if !AudioMux.isFrame(sb) { continue } // empty marker buffers carry nothing to copy
                if !vin.append(sb) {
                    fail(writer.error.map { Agent.message($0) } ?? "video append failed")
                    closeVideo()
                    return
                }
            }
        }

        private func closeVideo() {
            if !videoOpen { return }
            videoOpen = false
            vin.markAsFinished()
            group.leave()
        }

        /// On aq: blocks of the mix (the mic's copy of each goes to the transcription WAV), then silence up to the video's end.
        private func audioStep() {
            while audioOpen && ain.isReadyForMoreMediaData {
                if written >= audioFrames { closeAudio(); return }
                let n = Int(min(1024, audioFrames - written))
                var samples: [Float]
                if !mixDone, let m = mixer.next(n) {
                    samples = m
                    transcribe()
                    if samples.count < n * 2 { samples += [Float](repeating: 0, count: n * 2 - samples.count) }
                } else {
                    mixDone = true
                    samples = [Float](repeating: 0, count: n * 2) // apad
                }
                let pts = CMTimeAdd(start, CMTime(value: CMTimeValue(written), timescale: CMTimeScale(AudioMixer.rate)))
                guard let sb = AudioMux.pcmBuffer(samples, frames: n, pts: pts, format: format), ain.append(sb) else {
                    fail(writer.error.map { Agent.message($0) } ?? "audio append failed")
                    closeAudio()
                    return
                }
                written += Int64(n)
            }
        }

        private func closeAudio() {
            if !audioOpen { return }
            audioOpen = false
            ain.markAsFinished()
            group.leave()
        }

        /// The mic-only copy of what the mixer has read so far, to the WAV (dropped without a mic: there is no WAV).
        private func transcribe() {
            let m = mixer.takeTranscription()
            guard let w = wav, !m.isEmpty else { return }
            do { try w.write(down.process(m)) } catch { fail(Agent.message(error)) }
        }

        /// The transcription WAV is the mix's full length ([t] is not cut by -shortest): the rest of the mic, then the
        /// header. Without a mic there is no WAV.
        func drainTranscription() {
            aq.sync {
                if !mixDone && wav != nil { while mixer.next(4800) != nil { transcribe() } }
                mixDone = true
                transcribe()
                if let w = wav { do { try w.finish() } catch { fail(Agent.message(error)) } }
            }
        }
    }

    /// 48 kHz stereo float32 interleaved.
    static func pcmFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(AudioMixer.rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
                                               mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                                extensions: nil, formatDescriptionOut: &fd)
        return st == noErr ? fd : nil
    }

    static func pcmBuffer(_ samples: [Float], frames: Int, pts: CMTime, format: CMAudioFormatDescription) -> CMSampleBuffer? {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let b = block else { return nil }
        let st = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: b, offsetIntoDestination: 0, dataLength: bytes)
        }
        if st != noErr { return nil }
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: b, formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: pts, packetDescriptions: nil,
                                                                   sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
