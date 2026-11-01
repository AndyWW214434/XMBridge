import Testing
@testable import MDRKit

@Suite struct StateTests {
    /// `#expect` can't call a mutating method directly.
    func apply(_ state: inout HeadphoneState, _ payload: [UInt8]) -> Bool {
        state.apply(payload)
    }

    /// What a WH-1000XM5 advertises for the features this app uses (plus an unknown id).
    static let xm5Functions: [UInt8] = [0x12, 0x20, 0x23, 0x25, 0x50, 0x6b, 0xe2, 0xf1, 0xfc, 0x99]
    static let xm6Functions: [UInt8] = [0x12, 0x28, 0x23, 0x25, 0x50, 0x6d, 0xe2, 0xf1, 0xfc]

    static func supportReply(_ ids: [UInt8]) -> [UInt8] {
        [0x07, 0x00, UInt8(ids.count)] + ids.flatMap { [$0, 0x01] }
    }

    @Test func parsesDeviceInfo() {
        var state = HeadphoneState()
        #expect(apply(&state, [0x05, 0x01, 0x0a] + Array("WH-1000XM6".utf8)))
        #expect(apply(&state, [0x05, 0x02, 0x05] + Array("3.0.0".utf8)))
        #expect(state.modelName == "WH-1000XM6")
        #expect(state.firmwareVersion == "3.0.0")
    }

    @Test func xm5CapabilitiesDriveQueries() {
        var state = HeadphoneState()
        #expect(apply(&state, Self.supportReply(Self.xm5Functions)))
        #expect(state.batteryInquiry == .plain)
        #expect(state.noiseVariant == .dual)
        #expect(state.autoPowerOffInquiry == 0x05)
        #expect(state.initialQueries == [
            [0x12, 0x02],
            [0x22, 0x00],
            [0x66, 0x17],
            [0x50, 0x00, 0x01], [0x52, 0x00], [0x56, 0x00],
            [0xe6, 0x01],
            [0xf6, 0x0c], [0xfa, 0x0c],
            [0xf6, 0x01],
            [0x26, 0x05],
        ])
    }

    @Test func xm6UsesNoiseAdaptationAndThresholdBattery() {
        var state = HeadphoneState()
        state.apply(Self.supportReply(Self.xm6Functions))
        #expect(state.noiseVariant == .noiseAdaptation)
        #expect(state.batteryInquiry == .withThreshold)
        #expect(state.initialQueries.contains([0x66, 0x19]))
        #expect(state.initialQueries.contains([0x22, 0x08]))
    }

    /// Replies captured from a WH-1000XM6 on firmware 2.1.0.
    @Test func parsesRealXM6Session() throws {
        let replies: [[UInt8]] = [
            [0x05, 0x01, 0x0a] + Array("WH-1000XM6".utf8),
            [0x05, 0x02, 0x05] + Array("2.1.0".utf8),
            [0x07, 0x00, 0x2c, 0x10, 0xff, 0x12, 0xff, 0x13, 0xff, 0x14, 0xff, 0x15, 0xff, 0x16, 0xff, 0x17, 0xff,
             0x23, 0xff, 0x25, 0x36, 0x27, 0xff, 0x20, 0xff, 0x50, 0x11, 0x6d, 0x0b, 0x71, 0x02, 0x90, 0xff,
             0xa1, 0x12, 0xc1, 0xff, 0xc2, 0xff, 0xe2, 0x1b, 0xf1, 0x38, 0xfc, 0x0d, 0x69, 0x2a, 0xf9, 0x41,
             0xd1, 0x3b, 0xd3, 0x29, 0x94, 0xff, 0x41, 0x2f, 0x42, 0x3a, 0x44, 0xff, 0xff, 0x2d, 0xf4, 0x23,
             0xd2, 0x20, 0x19, 0xff, 0xe4, 0x0f, 0xe5, 0x10, 0xe6, 0x0e, 0xe7, 0x1a, 0xfd, 0x2b, 0xb6, 0x17,
             0xb0, 0x42, 0xb2, 0x43, 0xb8, 0x1f, 0xb7, 0x15, 0x34, 0x3f],
            [0x13, 0x02, 0x02],
            [0x23, 0x00, 0x51, 0x00],
            [0x67, 0x19, 0x01, 0x00, 0x01, 0x00, 0x14, 0x00, 0x00],
            [0x51, 0x00, 0x0a, 0x0d, 0x09, 0x00, 0x00, 0x30, 0x00, 0x31, 0x00, 0x32, 0x00, 0x33, 0x00,
             0x20, 0x00, 0xa0, 0x00, 0xa1, 0x00, 0xa2, 0x00],
            [0x53, 0x00, 0x00],
            [0x57, 0x00, 0xa1, 0x0a, 0x0b, 0x0a, 0x0a, 0x08, 0x09, 0x08, 0x07, 0x0a, 0x0a, 0x0a],
            [0xe7, 0x01, 0x00],
            [0xf7, 0x0c, 0x01, 0x01],
            [0xfb, 0x0c, 0x00, 0x01],
            [0xf7, 0x01, 0x00],
            [0x27, 0x05, 0x10, 0x00],
        ]
        var state = HeadphoneState()
        for reply in replies {
            #expect(apply(&state, reply), "unparsed: \(reply.hexString)")
        }

        #expect(state.modelName == "WH-1000XM6")
        #expect(state.firmwareVersion == "2.1.0")
        #expect(state.batteryInquiry == .plain)
        #expect(state.noiseVariant == .noiseAdaptation)
        #expect(state.autoPowerOffInquiry == 0x05)
        #expect(state.codec == .aac)
        #expect(state.battery == Battery(level: 81, status: .notCharging))
        #expect(state.noise?.mode == .off)
        #expect(state.noise?.ambientLevel == 20)
        #expect(state.eqPresets.map(\.name) == [
            "Off", "Heavy", "Clear", "Hard", "Soft", "Gaming", "Custom", "User Setting 1", "User Setting 2",
        ])
        let eq = try #require(state.equalizer)
        #expect(eq.presetID == 0xa1)
        #expect(eq.layout == .tenBands)
        #expect(eq.bands == [5, 4, 4, 2, 3, 2, 1, 4, 4, 4])
        #expect(state.upscaling == false)
        #expect(state.speakToChat == false)
        #expect(state.speakToChatSensitivity == .auto)
        #expect(state.speakToChatTimeout == .standard)
        #expect(state.pauseWhenTakenOff == true)
        #expect(state.autoPowerOff?.setting == .whenTakenOff)
    }

    @Test func parsesBatteryFormats() {
        var state = HeadphoneState()
        state.apply([0x23, 0x00, 0x50, 0x01])
        #expect(state.battery == Battery(level: 80, status: .charging))
        state.apply([0x25, 0x08, 0x2d, 0x00, 0x1e])
        #expect(state.battery == Battery(level: 45, status: .notCharging))
    }

    @Test func parsesXM5NoiseControl() throws {
        var state = HeadphoneState()
        #expect(apply(&state, [0x67, 0x17, 0x01, 0x01, 0x01, 0x01, 0x0f]))
        let noise = try #require(state.noise)
        #expect(noise.mode == .ambient)
        #expect(noise.focusOnVoice)
        #expect(noise.ambientLevel == 15)

        state.apply([0x69, 0x17, 0x01, 0x01, 0x00, 0x00, 0x0f])
        #expect(state.noise?.mode == .noiseCanceling)
        state.apply([0x69, 0x17, 0x01, 0x00, 0x00, 0x00, 0x0f])
        #expect(state.noise?.mode == .off)
    }

    @Test func parsesXM6NoiseControlWithAutoAmbient() throws {
        var state = HeadphoneState()
        #expect(apply(&state, [0x67, 0x19, 0x01, 0x01, 0x01, 0x00, 0x14, 0x01, 0x02]))
        let noise = try #require(state.noise)
        #expect(noise.mode == .ambient)
        #expect(noise.autoAmbient)
        #expect(noise.autoAmbientSensitivity == .low)
        // A truncated XM6 payload is rejected rather than half-applied.
        #expect(!apply(&state, [0x67, 0x19, 0x01, 0x00, 0x00, 0x00, 0x14]))
    }

    @Test func buildsNoiseControlCommands() {
        var noise = NoiseControl(isOn: true, isAmbient: false, focusOnVoice: false, ambientLevel: 20)
        #expect(Request.setNoiseControl(noise, variant: .dual) == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14])

        noise.mode = .ambient
        noise.focusOnVoice = true
        noise.ambientLevel = 7
        noise.autoAmbient = true
        noise.autoAmbientSensitivity = .high
        #expect(Request.setNoiseControl(noise, variant: .noiseAdaptation, adjusting: true)
            == [0x68, 0x19, 0x00, 0x01, 0x01, 0x01, 0x07, 0x01, 0x01])

        noise.mode = .off
        #expect(Request.setNoiseControl(noise, variant: .dual)[3] == 0x00)
    }

    @Test func parsesAndEncodesFiveBandEqualizer() throws {
        var state = HeadphoneState()
        // Custom preset, Clear Bass +3, bands -10, -2, 0, +4, +10
        state.apply([0x57, 0x00, 0xa0, 0x06, 0x0d, 0x00, 0x08, 0x0a, 0x0e, 0x14])
        let eq = try #require(state.equalizer)
        #expect(eq.layout == .fiveBandsWithClearBass)
        #expect(eq.clearBass == 3)
        #expect(eq.bands == [-10, -2, 0, 4, 10])
        #expect(Request.setEqBands(eq) == [0x58, 0x00, 0xa0, 0x06, 0x0d, 0x00, 0x08, 0x0a, 0x0e, 0x14])
    }

    @Test func parsesAndEncodesTenBandEqualizer() throws {
        var state = HeadphoneState()
        state.apply([0x59, 0x00, 0xa0, 0x0a, 0x00, 0x03, 0x06, 0x06, 0x06, 0x06, 0x07, 0x08, 0x09, 0x0c])
        var eq = try #require(state.equalizer)
        #expect(eq.layout == .tenBands)
        #expect(eq.bands == [-6, -3, 0, 0, 0, 0, 1, 2, 3, 6])

        eq.bands[0] = -20 // clamped to the band range
        let encoded = Request.setEqBands(eq)
        #expect(encoded.prefix(4) == [0x58, 0x00, 0xa0, 0x0a])
        #expect(encoded[4] == 0x00)
    }

    @Test func presetOnlyUpdateKeepsBands() {
        var state = HeadphoneState()
        state.apply([0x57, 0x00, 0xa0, 0x06, 0x0d, 0x00, 0x08, 0x0a, 0x0e, 0x14])
        state.apply([0x59, 0x00, 0x16, 0x00])
        #expect(state.equalizer?.presetID == 0x16)
        #expect(state.equalizer?.bands == [-10, -2, 0, 4, 10])
    }

    @Test func parsesPresetCapability() {
        var state = HeadphoneState()
        let reply: [UInt8] = [0x51, 0x00, 0x0a, 0x0d, 0x02, 0x30, 0x05] + Array("Heavy".utf8) + [0xa0, 0x00]
        #expect(apply(&state, reply))
        #expect(state.eqPresets == [EqPreset(id: 0x30, name: "Heavy"), EqPreset(id: 0xa0, name: "Custom")])
    }

    @Test func parsesSystemSettings() {
        var state = HeadphoneState()
        state.apply([0xf7, 0x0c, 0x00, 0x01])
        state.apply([0xf9, 0x01, 0x01])
        state.apply([0xfb, 0x0c, 0x02, 0x03])
        state.apply([0xe7, 0x01, 0x01])
        state.apply([0x27, 0x05, 0x10, 0x00])
        #expect(state.speakToChat == true)
        #expect(state.pauseWhenTakenOff == false)
        #expect(state.speakToChatSensitivity == .low)
        #expect(state.speakToChatTimeout == .never)
        #expect(state.upscaling == true)
        #expect(state.autoPowerOff == AutoPowerOff(inquiry: 0x05, setting: .whenTakenOff))
    }

    @Test func buildsSystemCommands() {
        #expect(Request.setSpeakToChat(true) == [0xf8, 0x0c, 0x00, 0x01])
        #expect(Request.setPauseWhenTakenOff(false) == [0xf8, 0x01, 0x01])
        #expect(Request.setUpscaling(true) == [0xe8, 0x01, 0x01])
        #expect(Request.setAutoPowerOff(AutoPowerOff(inquiry: 0x05, setting: .never)) == [0x28, 0x05, 0x11, 0x00])
        #expect(Request.setAutoPowerOff(AutoPowerOff(inquiry: 0x05, setting: .after1Hour)) == [0x28, 0x05, 0x02, 0x02])
    }
}
