import AppKit
import AVFoundation
import CoreAudioKit  // AUAudioUnit.requestViewController(completionHandler:)
import SwiftUI

/// Shows an Audio Unit's own UI in a window, with playback controls under it
/// (see AudioUnitPlaybackPanel). Nothing renders until the user presses Play
/// or a note, so opening a plugin `auval` refuses to clear or times out on is
/// still just a look at it, without trusting the automated verdict alone.
///
/// Kept alive via `open`, since neither the window nor the `AVAudioUnit` is
/// retained by anything else — closing the window releases both.
@MainActor
final class AudioUnitPreviewWindowController: NSObject, NSWindowDelegate {
    private static var open: [AudioUnitPreviewWindowController] = []

    private let audioUnit: AVAudioUnit
    private let playback: AudioUnitPlayback
    private var window: NSWindow?

    private init(audioUnit: AVAudioUnit) {
        self.audioUnit = audioUnit
        playback = AudioUnitPlayback(audioUnit: audioUnit)
    }

    /// Instantiates `desc` and opens its view. Reports a failure via
    /// `onError` (called on the main actor) instead of throwing, since the
    /// underlying AVFoundation callback isn't structured-concurrency-friendly.
    static func present(_ desc: AudioComponentDescription, pluginName: String, onError: @escaping (String) -> Void) {
        // Ask the system to host it in a separate process when the plugin
        // supports that — the same isolation "Test All" uses, so a plugin
        // that crashes can't take AudioBunny down with it.
        AVAudioUnit.instantiate(with: desc, options: [.loadOutOfProcess]) { avAudioUnit, error in
            Task { @MainActor in
                guard let avAudioUnit, error == nil else {
                    onError(error?.localizedDescription ?? "Couldn't open \(pluginName).")
                    return
                }
                let controller = AudioUnitPreviewWindowController(audioUnit: avAudioUnit)
                open.append(controller)
                controller.show(pluginName: pluginName)
            }
        }
    }

    private func show(pluginName: String) {
        audioUnit.auAudioUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self else { return }
                let content = AudioUnitWindowContent(
                    viewController: audioUnitViewController(viewController, for: self.audioUnit),
                    playback: self.playback)
                let hosting = NSHostingController(rootView: content)
                // Follow the content, so hiding the plugin's UI shrinks the window.
                hosting.sizingOptions = [.preferredContentSize]
                let window = NSWindow(contentViewController: hosting)
                window.title = pluginName
                window.styleMask = [.titled, .closable, .miniaturizable]
                window.isReleasedWhenClosed = false
                window.delegate = self
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self.window = window
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            self.playback.shutdown()
            Self.open.removeAll { $0 === self }
        }
    }
}
