import AVFoundation

/// Plays a test signal (or MIDI) through one Audio Unit to the default output
/// device: source → Audio Unit → main mixer → speakers.
///
/// Deliberately not `@MainActor`: the tone and noise render blocks are built
/// in this class's nonisolated methods, so they never inherit main-actor
/// isolation (which would trap when the audio thread calls them; see
/// docs/rules/audio-plugins.md). Callers still use it from the main thread.
///
/// The render blocks never allocate, lock or log. Their only state is a phase
/// and a noise seed in memory allocated once here and freed in `deinit`.
final class AudioUnitPlaybackEngine {
    private let engine = AVAudioEngine()
    private let audioUnit: AVAudioUnit
    private let role: AudioUnitRole
    /// Nodes added for the current run, detached again by `stop()`.
    private var addedNodes: [AVAudioNode] = []
    private var player: AVAudioPlayerNode?
    private var meterTapInstalled = false

    private let phase = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let noiseSeed = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)

    init(audioUnit: AVAudioUnit, role: AudioUnitRole) {
        self.audioUnit = audioUnit
        self.role = role
        phase.initialize(to: 0)
        noiseSeed.initialize(to: 0x9E37_79B9)
        engine.attach(audioUnit)
    }

    deinit {
        stop()
        engine.detach(audioUnit)
        phase.deallocate()
        noiseSeed.deallocate()
    }

    var isRunning: Bool { engine.isRunning }

    /// The engine posts this when the output device changes, and stops itself.
    var configurationChangeObject: AVAudioEngine { engine }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Wires the graph for `signal` and starts it. `onPeak` gets the output's
    /// peak sample value roughly every 20 ms, on a background thread.
    func start(signal: TestSignal, file: URL?, volume: Float, onPeak: @escaping (Float) -> Void) throws {
        stop()
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000

        let outputFormat = Self.format(sampleRate: sampleRate, channels: audioUnit.outputFormat(forBus: 0).channelCount)
        engine.connect(audioUnit, to: engine.mainMixerNode, format: outputFormat)

        if role.takesAudio, audioUnit.numberOfInputs > 0 {
            // Sources feed a mixer that converts to whatever channel count the
            // plugin's input wants, so a mono effect or a 44.1 kHz file still
            // connects.
            let inputFormat = Self.format(sampleRate: sampleRate, channels: audioUnit.inputFormat(forBus: 0).channelCount)
            let premix = AVAudioMixerNode()
            add(premix)
            engine.connect(premix, to: audioUnit, format: inputFormat)
            try connectSource(signal, file: file, sampleRate: sampleRate, to: premix)
        }

        engine.mainMixerNode.outputVolume = volume
        installMeter(onPeak)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            throw error
        }
        player?.play()
    }

    func stop() {
        if engine.isRunning { sendMIDI(MIDIMessage.allNotesOff()) }
        if meterTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            meterTapInstalled = false
        }
        player?.stop()
        player = nil
        engine.stop()
        engine.disconnectNodeInput(audioUnit)
        engine.disconnectNodeOutput(audioUnit)
        for node in addedNodes { engine.detach(node) }
        addedNodes = []
    }

    /// Sends a raw MIDI message to the plugin. Only works while running: the
    /// plugin's MIDI block exists once render resources are allocated.
    func sendMIDI(_ bytes: [UInt8]) {
        guard engine.isRunning else { return }
        if let block = audioUnit.auAudioUnit.scheduleMIDIEventBlock {
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                block(AUEventSampleTimeImmediate, 0, buffer.count, base)
            }
        } else if let instrument = audioUnit as? AVAudioUnitMIDIInstrument, bytes.count == 3 {
            instrument.sendMIDIEvent(bytes[0], data1: bytes[1], data2: bytes[2])
        }
    }

    // MARK: - Graph

    private func add(_ node: AVAudioNode) {
        engine.attach(node)
        addedNodes.append(node)
    }

    private func connectSource(_ signal: TestSignal, file: URL?, sampleRate: Double, to premix: AVAudioMixerNode) throws {
        let mono = Self.format(sampleRate: sampleRate, channels: 1)
        switch signal {
        case .tone:
            let node = Self.toneNode(format: mono, phase: phase)
            add(node)
            engine.connect(node, to: premix, format: mono)
        case .noise:
            let node = Self.noiseNode(format: mono, seed: noiseSeed)
            add(node)
            engine.connect(node, to: premix, format: mono)
        case .file:
            guard let file else { throw PlaybackError.noFile }
            let audioFile = try AVAudioFile(forReading: file)
            let format = audioFile.processingFormat
            let frames = AVAudioFrameCount(min(Double(audioFile.length), TestSignal.maxFileSeconds * format.sampleRate))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw PlaybackError.emptyFile
            }
            try audioFile.read(into: buffer, frameCount: frames)
            let player = AVAudioPlayerNode()
            add(player)
            engine.connect(player, to: premix, format: format)
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            self.player = player
        }
    }

    private func installMeter(_ onPeak: @escaping (Float) -> Void) {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(samples[frame]))
                }
            }
            onPeak(peak)
        }
        meterTapInstalled = true
    }

    private static func format(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat {
        // Clamp to 1–2 channels: the main mixer handles those everywhere, and
        // a plugin reporting 0 channels before render setup still connects.
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: min(max(channels, 1), 2))!
    }

    // MARK: - Render blocks (audio thread)

    private static func toneNode(format: AVAudioFormat, phase: UnsafeMutablePointer<Double>) -> AVAudioSourceNode {
        let increment = 2 * Double.pi * TestSignal.toneFrequency / format.sampleRate
        let amplitude = TestSignal.toneAmplitude
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            var current = phase.pointee
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(current)) * amplitude
                current += increment
                if current >= 2 * Double.pi { current -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            phase.pointee = current
            return noErr
        }
    }

    private static func noiseNode(format: AVAudioFormat, seed: UnsafeMutablePointer<UInt32>) -> AVAudioSourceNode {
        let amplitude = TestSignal.noiseAmplitude
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            var state = seed.pointee
            for frame in 0..<Int(frameCount) {
                // xorshift32: cheap, allocation-free white noise.
                state ^= state << 13
                state ^= state >> 17
                state ^= state << 5
                let sample = (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            seed.pointee = state
            return noErr
        }
    }
}

enum PlaybackError: LocalizedError {
    case noFile
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .noFile: return "Choose an audio file to play through the plugin."
        case .emptyFile: return "That audio file is empty."
        }
    }
}
