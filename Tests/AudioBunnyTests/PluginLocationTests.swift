import XCTest
@testable import AudioBunny

@MainActor
final class PluginLocationTests: XCTestCase {

    func testAudioUnitsSharingABundleShowOneLocation() {
        let bundle = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components/Reason Rack Plugin.component")
        let instrument = AudioPlugin(name: "Reason Rack Plugin", manufacturer: "Reason Studios", type: .audioUnit, fileURL: bundle)
        let midiEffect = AudioPlugin(name: "Reason Rack Plugin", manufacturer: "Reason Studios", type: .audioUnit, fileURL: bundle)
        let vst3 = AudioPlugin(name: "Reason Rack Plugin", manufacturer: "Reason Studios", type: .vst3,
                               fileURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3/Reason Rack Plugin.vst3"))

        let locations = uniqueInstallLocations([instrument, midiEffect, vst3])

        XCTAssertEqual(locations.count, 2)
        XCTAssertTrue(locations[0] === instrument)
        XCTAssertTrue(locations[1] === vst3)
    }

    func testSameBundleInTwoFoldersKeepsBoth() {
        let system = AudioPlugin(name: "Foo", manufacturer: "Bar", type: .audioUnit,
                                 fileURL: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components/Foo.component"))
        let user = AudioPlugin(name: "Foo", manufacturer: "Bar", type: .audioUnit,
                               fileURL: URL(fileURLWithPath: "/Users/x/Library/Audio/Plug-Ins/Components/Foo.component"))

        XCTAssertEqual(uniqueInstallLocations([system, user]).count, 2)
    }
}
