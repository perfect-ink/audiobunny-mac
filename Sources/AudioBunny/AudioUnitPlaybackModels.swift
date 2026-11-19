import AudioToolbox
import Foundation

// Pure data for playing a signal through an Audio Unit (see
// AudioUnitPlaybackEngine and AudioUnitPlaybackPanel). Nothing here touches
// AVFoundation objects, so it's all unit-testable.

/// What an Audio Unit expects to be fed, from its component type.
enum AudioUnitRole: Equatable {
    /// Audio in, audio out (`aufx`, `aufc`, `auol`).
    case effect
    /// Audio and MIDI in, audio out (`aumf`).
    case musicEffect
    /// MIDI in, audio out (`aumu`).
    case instrument
    /// Makes its own audio; nothing to feed it (`augn`).
    case generator

    /// nil for units AudioBunny can't meaningfully play through: mixers,
    /// panners, output units, MIDI processors (which output MIDI, not audio)
    /// and speech synthesizers.
    init?(componentType: OSType) {
        switch componentType {
        case kAudioUnitType_Effect, kAudioUnitType_FormatConverter, kAudioUnitType_OfflineEffect:
            self = .effect
        case kAudioUnitType_MusicEffect:
            self = .musicEffect
        case kAudioUnitType_MusicDevice:
            self = .instrument
        case kAudioUnitType_Generator:
            self = .generator
        default:
            return nil
        }
    }

    var takesAudio: Bool { self == .effect || self == .musicEffect }
    var takesMIDI: Bool { self == .instrument || self == .musicEffect }
}

/// The signal fed into an effect.
enum TestSignal: String, CaseIterable, Identifiable {
    case tone
    case noise
    case file

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tone: return "Tone"
        case .noise: return "Noise"
        case .file: return "File"
        }
    }

    static let toneFrequency = 440.0
    /// About -12 dBFS, loud enough to hear an effect without being harsh.
    static let toneAmplitude: Float = 0.25
    /// About -18 dBFS; white noise sounds louder than a sine at the same peak.
    static let noiseAmplitude: Float = 0.125
    /// Longer files are cut to this so loading one can't eat memory.
    static let maxFileSeconds = 120.0
}

/// MIDI notes from the computer keyboard, laid out like a piano: the home row
/// plays the white keys from C, the row above the black keys.
enum ComputerKeyboard {
    static let noteOffsets: [Character: Int] = [
        "a": 0, "w": 1, "s": 2, "e": 3, "d": 4, "f": 5, "t": 6,
        "g": 7, "y": 8, "h": 9, "u": 10, "j": 11, "k": 12, "o": 13, "l": 14,
    ]
    static let octaveDown: Character = "z"
    static let octaveUp: Character = "x"
    static let octaveRange = 0...8

    /// The MIDI note for `key` with the keyboard's C in `octave` (C4 = 60).
    static func note(for key: Character, octave: Int) -> UInt8? {
        guard let offset = noteOffsets[Character(key.lowercased())] else { return nil }
        return midiNote(baseNote(octave: octave) + offset)
    }

    static func baseNote(octave: Int) -> Int { (octave + 1) * 12 }

    static func midiNote(_ value: Int) -> UInt8? {
        (0...127).contains(value) ? UInt8(value) : nil
    }
}

/// The on-screen keyboard's keys, positioned in white-key widths.
struct PianoKey: Equatable, Identifiable {
    let note: UInt8
    let isBlack: Bool
    /// Left edge, in white-key widths from the keyboard's left edge.
    let position: Double

    var id: UInt8 { note }

    static let blackKeyWidth = 0.6

    /// Keys from `lowNote` up through `count` semitones. Black keys sit
    /// centred on the line between their neighbouring white keys.
    static func layout(lowNote: Int, count: Int) -> [PianoKey] {
        var keys: [PianoKey] = []
        var whiteIndex = 0
        for value in lowNote..<(lowNote + count) {
            guard let note = ComputerKeyboard.midiNote(value) else { continue }
            if isBlackKey(value) {
                keys.append(PianoKey(note: note, isBlack: true, position: Double(whiteIndex) - blackKeyWidth / 2))
            } else {
                keys.append(PianoKey(note: note, isBlack: false, position: Double(whiteIndex)))
                whiteIndex += 1
            }
        }
        return keys
    }

    static func isBlackKey(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((note % 12) + 12) % 12)
    }

    static func whiteKeyCount(_ keys: [PianoKey]) -> Int {
        keys.filter { !$0.isBlack }.count
    }
}

enum MIDIMessage {
    static func noteOn(_ note: UInt8, velocity: UInt8 = 100, channel: UInt8 = 0) -> [UInt8] {
        [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
    }

    static func noteOff(_ note: UInt8, channel: UInt8 = 0) -> [UInt8] {
        [0x80 | (channel & 0x0F), note & 0x7F, 0]
    }

    /// CC 123, All Notes Off, so nothing hangs when playback stops.
    static func allNotesOff(channel: UInt8 = 0) -> [UInt8] {
        [0xB0 | (channel & 0x0F), 123, 0]
    }
}

/// Note names like "C4" (middle C = 60).
func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[((note % 12) + 12) % 12])\(note / 12 - 1)"
}

/// A peak sample value (0…1+) as a meter fill, on a -60…0 dBFS scale.
func meterFraction(peak: Float) -> Float {
    guard peak > 0 else { return 0 }
    let db = 20 * log10(peak)
    return min(1, max(0, (db + 60) / 60))
}
