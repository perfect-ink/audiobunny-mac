import AudioToolbox
import XCTest
@testable import AudioBunny

final class AudioUnitPlaybackTests: XCTestCase {

    func testRoleFromComponentType() {
        XCTAssertEqual(AudioUnitRole(componentType: kAudioUnitType_Effect), .effect)
        XCTAssertEqual(AudioUnitRole(componentType: kAudioUnitType_FormatConverter), .effect)
        XCTAssertEqual(AudioUnitRole(componentType: kAudioUnitType_MusicEffect), .musicEffect)
        XCTAssertEqual(AudioUnitRole(componentType: kAudioUnitType_MusicDevice), .instrument)
        XCTAssertEqual(AudioUnitRole(componentType: kAudioUnitType_Generator), .generator)
        XCTAssertNil(AudioUnitRole(componentType: kAudioUnitType_Mixer))
        XCTAssertNil(AudioUnitRole(componentType: kAudioUnitType_Output))
        XCTAssertNil(AudioUnitRole(componentType: kAudioUnitType_MIDIProcessor))
    }

    func testWhatEachRoleIsFed() {
        XCTAssertTrue(AudioUnitRole.effect.takesAudio)
        XCTAssertFalse(AudioUnitRole.effect.takesMIDI)
        XCTAssertTrue(AudioUnitRole.musicEffect.takesAudio)
        XCTAssertTrue(AudioUnitRole.musicEffect.takesMIDI)
        XCTAssertFalse(AudioUnitRole.instrument.takesAudio)
        XCTAssertTrue(AudioUnitRole.instrument.takesMIDI)
        XCTAssertFalse(AudioUnitRole.generator.takesAudio)
        XCTAssertFalse(AudioUnitRole.generator.takesMIDI)
    }

    func testComputerKeyboardNotes() {
        XCTAssertEqual(ComputerKeyboard.note(for: "a", octave: 4), 60)
        XCTAssertEqual(ComputerKeyboard.note(for: "W", octave: 4), 61)
        XCTAssertEqual(ComputerKeyboard.note(for: "k", octave: 4), 72)
        XCTAssertEqual(ComputerKeyboard.note(for: "a", octave: 0), 12)
        XCTAssertNil(ComputerKeyboard.note(for: "q", octave: 4))
        XCTAssertNil(ComputerKeyboard.note(for: "l", octave: 9), "past MIDI note 127")
    }

    func testPianoLayoutFromC() {
        let keys = PianoKey.layout(lowNote: 60, count: 13)

        XCTAssertEqual(keys.count, 13)
        XCTAssertEqual(PianoKey.whiteKeyCount(keys), 8)
        XCTAssertEqual(keys[0], PianoKey(note: 60, isBlack: false, position: 0))
        XCTAssertEqual(keys[1], PianoKey(note: 61, isBlack: true, position: 1 - PianoKey.blackKeyWidth / 2))
        XCTAssertEqual(keys[5], PianoKey(note: 65, isBlack: false, position: 3), "F is the fourth white key")
        XCTAssertEqual(keys[12], PianoKey(note: 72, isBlack: false, position: 7))
    }

    func testMIDIMessages() {
        XCTAssertEqual(MIDIMessage.noteOn(60), [0x90, 60, 100])
        XCTAssertEqual(MIDIMessage.noteOff(60, channel: 2), [0x82, 60, 0])
        XCTAssertEqual(MIDIMessage.allNotesOff(), [0xB0, 123, 0])
    }

    func testNoteNames() {
        XCTAssertEqual(noteName(60), "C4")
        XCTAssertEqual(noteName(69), "A4")
        XCTAssertEqual(noteName(61), "C♯4")
        XCTAssertEqual(noteName(12), "C0")
    }

    func testMeterFraction() {
        XCTAssertEqual(meterFraction(peak: 0), 0)
        XCTAssertEqual(meterFraction(peak: 1), 1)
        XCTAssertEqual(meterFraction(peak: 2), 1, "clipping stays full")
        XCTAssertEqual(meterFraction(peak: 0.001), 0, accuracy: 0.001)
        XCTAssertEqual(meterFraction(peak: 0.0316), 0.5, accuracy: 0.01)
    }
}
