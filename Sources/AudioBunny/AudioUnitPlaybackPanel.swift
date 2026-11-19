import AppKit
import AVFoundation
import CoreAudioKit  // AUGenericViewController
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// Playback controls for one open Audio Unit: play a tone, noise or audio
/// file through an effect, or MIDI notes into an instrument, and hear it on
/// the default output device. Nothing renders until Play (or a note) starts
/// it, so just opening a plugin still only shows its UI.
@MainActor
final class AudioUnitPlayback: ObservableObject {
    /// nil when the unit isn't something AudioBunny can play through.
    let role: AudioUnitRole?

    @Published private(set) var isPlaying = false
    @Published private(set) var signal: TestSignal = .tone
    @Published private(set) var fileURL: URL?
    @Published var volume: Float = 0.5 {
        didSet { engine?.volume = volume }
    }
    /// Output level as a meter fill, 0…1.
    @Published private(set) var level: Float = 0
    @Published private(set) var octave = 4
    @Published private(set) var heldNotes: Set<UInt8> = []
    @Published var errorMessage: String?

    private var engine: AudioUnitPlaybackEngine?
    private var keyMonitor: Any?
    private weak var keyboardWindow: NSWindow?
    private var configurationObserver: NSObjectProtocol?
    /// The note each held computer key started, so changing octave mid-hold
    /// still releases the right one.
    private var keyNotes: [Character: UInt8] = [:]

    init(audioUnit: AVAudioUnit) {
        role = AudioUnitRole(componentType: audioUnit.audioComponentDescription.componentType)
        guard let role else { return }
        let engine = AudioUnitPlaybackEngine(audioUnit: audioUnit, role: role)
        self.engine = engine
        // Switching output devices stops the engine; pick up where it was.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.configurationChangeObject,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartIfPlaying() }
        }
    }

    // MARK: Transport

    func togglePlaying() {
        isPlaying ? stop() : play()
    }

    func play() {
        guard let engine else { return }
        do {
            try engine.start(signal: signal, file: fileURL, volume: volume,
                             onPeak: Self.peakForwarder(to: self))
            isPlaying = true
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = "Couldn't play: \(error.localizedDescription)"
        }
    }

    func stop() {
        engine?.stop()
        isPlaying = false
        heldNotes = []
        keyNotes = [:]
        level = 0
    }

    /// Stops audio and drops the keyboard monitor; call when the window closes.
    func shutdown() {
        stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
    }

    private func restartIfPlaying() {
        guard isPlaying else { return }
        stop()
        play()
    }

    /// Built outside the main actor's isolation: the engine calls it from
    /// its meter tap, off the main thread.
    nonisolated private static func peakForwarder(to playback: AudioUnitPlayback) -> (Float) -> Void {
        { [weak playback] peak in
            Task { @MainActor in
                guard let playback, playback.isPlaying else { return }
                playback.level = meterFraction(peak: peak)
            }
        }
    }

    // MARK: Signal

    func select(_ newSignal: TestSignal) {
        if newSignal == .file, fileURL == nil {
            chooseFile()
            return
        }
        signal = newSignal
        restartIfPlaying()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to loop through the plugin."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        signal = .file
        restartIfPlaying()
    }

    // MARK: MIDI

    func noteOn(_ note: UInt8) {
        guard role?.takesMIDI == true, !heldNotes.contains(note) else { return }
        if !isPlaying { play() }
        guard isPlaying else { return }
        heldNotes.insert(note)
        engine?.sendMIDI(MIDIMessage.noteOn(note))
    }

    func noteOff(_ note: UInt8) {
        guard heldNotes.remove(note) != nil else { return }
        engine?.sendMIDI(MIDIMessage.noteOff(note))
    }

    func shiftOctave(_ delta: Int) {
        let next = octave + delta
        guard ComputerKeyboard.octaveRange.contains(next) else { return }
        octave = next
    }

    /// Plays notes from the computer keyboard while `window` is key. Typing
    /// into a text field (including one in the plugin's own UI) still types.
    func attachKeyboard(to window: NSWindow) {
        guard role?.takesMIDI == true, keyboardWindow !== window else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyboardWindow = window
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.keyboardWindow, event.window === window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    /// True when the key was used (and shouldn't reach anything else).
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              !(event.window?.firstResponder is NSText),
              let key = event.charactersIgnoringModifiers?.lowercased().first else { return false }

        if event.type == .keyDown {
            if key == ComputerKeyboard.octaveDown || key == ComputerKeyboard.octaveUp {
                if !event.isARepeat { shiftOctave(key == ComputerKeyboard.octaveUp ? 1 : -1) }
                return true
            }
            guard ComputerKeyboard.noteOffsets[key] != nil else { return false }
            guard !event.isARepeat, keyNotes[key] == nil,
                  let note = ComputerKeyboard.note(for: key, octave: octave) else { return true }
            keyNotes[key] = note
            noteOn(note)
            return true
        }

        guard let note = keyNotes.removeValue(forKey: key) else {
            return ComputerKeyboard.noteOffsets[key] != nil
        }
        noteOff(note)
        return true
    }
}

// MARK: - Window content

/// An Audio Unit's window: its own UI (which the user can hide) above the
/// playback controls. Shared by "Open Plugin" and plugin bundles opened from
/// Finder.
struct AudioUnitWindowContent: View {
    let viewController: NSViewController
    @ObservedObject var playback: AudioUnitPlayback
    /// Remembered across windows, so someone who only wants the controls
    /// doesn't have to hide every plugin's UI one at a time.
    @AppStorage("showAudioUnitView") private var showPlugin = true

    var body: some View {
        VStack(spacing: 0) {
            if showPlugin {
                AudioUnitViewHost(viewController: viewController)
                Divider()
            }
            AudioUnitPlaybackPanel(playback: playback, showPlugin: $showPlugin)
        }
    }
}

/// The plugin's own view controller, or Apple's generic parameter view for
/// units that have none (mixers, converters, many of Apple's built-ins).
func audioUnitViewController(_ viewController: NSViewController?, for audioUnit: AVAudioUnit) -> NSViewController {
    if let viewController { return viewController }
    let generic = AUGenericViewController()
    generic.auAudioUnit = audioUnit.auAudioUnit
    return generic
}

/// An Audio Unit's own view controller, at the size the plugin asks for.
struct AudioUnitViewHost: NSViewControllerRepresentable {
    let viewController: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { viewController }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSViewController, context: Context) -> CGSize? {
        let preferred = nsViewController.preferredContentSize
        if preferred.width > 0, preferred.height > 0 { return preferred }
        let frame = nsViewController.view.frame.size
        if frame.width > 0, frame.height > 0 { return frame }
        return CGSize(width: 600, height: 400)
    }
}

// MARK: - Panel

struct AudioUnitPlaybackPanel: View {
    @ObservedObject var playback: AudioUnitPlayback
    @Binding var showPlugin: Bool

    private static let keyCount = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let role = playback.role {
                    Button(action: playback.togglePlaying) {
                        Label(playback.isPlaying ? "Stop" : "Play",
                              systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                            .frame(minWidth: 52)
                    }
                    .help(playback.isPlaying ? "Stop playback" : "Play through the plugin")

                    if role.takesAudio { signalControls }
                } else {
                    Text("AudioBunny can't play sound through this kind of Audio Unit.")
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if playback.role != nil {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                    Slider(value: $playback.volume, in: 0...1)
                        .frame(width: 100)
                        .help("Output volume")
                    LevelMeter(level: playback.level)
                        .frame(width: 80, height: 6)
                }

                Button {
                    showPlugin.toggle()
                } label: {
                    Image(systemName: showPlugin ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .help(showPlugin ? "Hide the plugin's window" : "Show the plugin's window")
                .accessibilityLabel(showPlugin ? "Hide plugin" : "Show plugin")
            }

            if playback.role?.takesMIDI == true { keyboard }

            if let message = playback.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(minWidth: 560)
        .background(.bar)
        .background(WindowReader { playback.attachKeyboard(to: $0) })
    }

    @ViewBuilder
    private var signalControls: some View {
        Picker("Signal", selection: Binding(get: { playback.signal }, set: { playback.select($0) })) {
            ForEach(TestSignal.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("What to feed the plugin: a 440 Hz tone, white noise, or a looped audio file")

        if playback.signal == .file, let url = playback.fileURL {
            Button(url.lastPathComponent, action: playback.chooseFile)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
                .help("Choose a different audio file")
        }
    }

    private var keyboard: some View {
        let lowNote = ComputerKeyboard.baseNote(octave: playback.octave)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { playback.shiftOctave(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Octave down (Z)")
                    .disabled(playback.octave == ComputerKeyboard.octaveRange.lowerBound)
                Text(noteName(lowNote))
                    .monospacedDigit()
                    .frame(width: 34)
                Button { playback.shiftOctave(1) } label: { Image(systemName: "chevron.right") }
                    .help("Octave up (X)")
                    .disabled(playback.octave == ComputerKeyboard.octaveRange.upperBound)
                PianoKeyboardView(lowNote: lowNote, count: Self.keyCount, heldNotes: playback.heldNotes,
                                  onDown: playback.noteOn, onUp: playback.noteOff)
                    .frame(height: 64)
            }
            Text("Play with A–L on your keyboard (W E T Y U O for sharps). Z and X change octave.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(level > 0.95 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * CGFloat(level))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Output level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - On-screen keyboard

struct PianoKeyboardView: View {
    let lowNote: Int
    let count: Int
    let heldNotes: Set<UInt8>
    let onDown: (UInt8) -> Void
    let onUp: (UInt8) -> Void

    var body: some View {
        let keys = PianoKey.layout(lowNote: lowNote, count: count)
        let whiteCount = CGFloat(max(PianoKey.whiteKeyCount(keys), 1))
        GeometryReader { geometry in
            let whiteWidth = geometry.size.width / whiteCount
            ZStack(alignment: .topLeading) {
                ForEach(keys.filter { !$0.isBlack }) { key in
                    keyView(key, width: whiteWidth - 1, height: geometry.size.height, whiteWidth: whiteWidth)
                }
                ForEach(keys.filter(\.isBlack)) { key in
                    keyView(key, width: whiteWidth * PianoKey.blackKeyWidth,
                            height: geometry.size.height * 0.6, whiteWidth: whiteWidth)
                }
            }
        }
    }

    private func keyView(_ key: PianoKey, width: CGFloat, height: CGFloat, whiteWidth: CGFloat) -> some View {
        PianoKeyView(key: key, isHeld: heldNotes.contains(key.note), onDown: onDown, onUp: onUp)
            .frame(width: width, height: height)
            .offset(x: CGFloat(key.position) * whiteWidth)
    }
}

private struct PianoKeyView: View {
    let key: PianoKey
    let isHeld: Bool
    let onDown: (UInt8) -> Void
    let onUp: (UInt8) -> Void
    @State private var pressed = false
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        onDown(key.note)
                    }
                    .onEnded { _ in
                        pressed = false
                        onUp(key.note)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(noteName(Int(key.note)))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                onDown(key.note)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onUp(key.note) }
            }
    }

    private var fill: Color {
        if isHeld { return .accentColor }
        if key.isBlack { return hovering ? Color(white: 0.3) : Color(white: 0.1) }
        return hovering ? Color(white: 0.88) : .white
    }
}

/// Hands the hosting NSWindow to `onWindow` once the view is in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
