# Plugin Playback

Play sound through an Audio Unit to hear whether it works, without a DAW.

## What it does

Every Audio Unit window has a playback bar under the plugin's own UI. That includes "Open Plugin" from My Plugins and `.component` bundles opened from Finder or dragged into the window.

- **Effects** (`aufx`, `aufc`, `auol`): **Play** loops a signal into the plugin. Pick a 440 Hz tone (about -12 dBFS), white noise (about -18 dBFS), or an audio file (the first 120 seconds, looped).
- **Instruments** (`aumu`): an on-screen two-octave keyboard, plus the computer keyboard: A–L play white keys from C, W E T Y U O the sharps, Z and X shift the octave. Playing a note starts playback if it isn't running.
- **Music effects** (`aumf`) get both the signal picker and the keyboard. **Generators** (`augn`) just play.
- Output goes to the default output device through a volume slider (starts at 50%) and a level meter (-60 to 0 dBFS, red near clipping). Switching output devices restarts playback.
- Mixers, panners, output units, MIDI processors and speech synthesizers show the bar with a note that AudioBunny can't play through them.
- **Show/hide the plugin:** the button at the right of the bar hides the plugin's UI and leaves the controls. The choice is remembered for every plugin window (`showAudioUnitView` in user defaults).
- Units with no UI of their own (Apple's mixers and converters, among others) show Apple's generic parameter view instead of "doesn't provide a custom view".

Nothing renders until Play or a note starts it, so opening a plugin is still just a look at it.

## How it works

- `AudioUnitPlaybackEngine` builds an `AVAudioEngine` graph: source → mixer (converts channels and sample rate) → Audio Unit → main mixer → output. It is deliberately not `@MainActor`, so the tone and noise render blocks never inherit main-actor isolation. The render blocks don't allocate or lock; their phase and noise seed live in memory allocated once.
- MIDI goes through the unit's `scheduleMIDIEventBlock`, which exists only while the engine runs. Stopping sends All Notes Off.
- `AudioUnitPlayback` is the window's model (transport, signal, notes, computer-keyboard monitor). `AudioUnitWindowContent` and `AudioUnitPlaybackPanel` are the views. Pure logic is in `AudioUnitPlaybackModels.swift`.
- Installed plugins load out of process, as before, so a crashing plugin can't take AudioBunny down. Bundles that aren't installed still load in process (see `registerComponentBundleInProcess`).

## Who can use it

Anyone running the app; there are no accounts or permissions involved.

## Tests

`Tests/AudioBunnyTests/AudioUnitPlaybackTests.swift` covers unit roles, computer-keyboard notes, keyboard layout, MIDI bytes, note names and meter scaling.

## Known limits

- Audio Units only. VST2 and VST3 would need a full plugin host.
- No microphone or audio-interface input, and no external MIDI controllers yet.
- The tone is fixed at 440 Hz. There's no sweep, level control or sample-rate choice.
- One window, one engine: two open plugins play side by side, not chained.

## History

- Implemented 2026-11-19, along with the generic-view fallback and the show/hide button. Not deployed (local builds only). Verified: unit tests, a throwaway harness that played a tone through AULowpass, noise through AUDelay and a MIDI note into AUMIDISynth out of process and measured output, and screenshots of the OTT (effect) and Reaktor 6 (instrument) windows. Not verified: clicking the controls in the app (the session had no accessibility access) and listening by ear.
