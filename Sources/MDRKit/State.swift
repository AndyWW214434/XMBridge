// Headphone settings as last reported by the device, and the parser that keeps them current.
// Every RET (reply) and NTFY (change made on the headset) payload goes through `HeadphoneState.apply`.

import Foundation

public enum BatteryInquiry: UInt8, Sendable {
    case plain = 0x00
    case withThreshold = 0x08
}

public struct Battery: Equatable, Sendable {
    public enum Status: UInt8, Sendable {
        case notCharging = 0x00
        case charging = 0x01
        case unknown = 0x02
        case charged = 0x03
    }

    public var level: Int
    public var status: Status

    public var isCharging: Bool { status == .charging }
}

public enum AudioCodec: UInt8, Sendable {
    case unsettled = 0x00
    case sbc = 0x01
    case aac = 0x02
    case ldac = 0x10
    case aptX = 0x20
    case aptXHD = 0x21
    case lc3 = 0x30
    case other = 0xff

    public var name: String {
        switch self {
        case .unsettled: return "—"
        case .sbc: return "SBC"
        case .aac: return "AAC"
        case .ldac: return "LDAC"
        case .aptX: return "aptX"
        case .aptXHD: return "aptX HD"
        case .lc3: return "LC3"
        case .other: return "Other"
        }
    }
}

// MARK: - Noise control

public enum NoiseControlVariant: UInt8, Sendable {
    case autoNC = 0x15
    case dual = 0x17
    case noiseAdaptation = 0x19
}

public enum AutoAmbientSensitivity: UInt8, CaseIterable, Sendable {
    case standard = 0x00
    case high = 0x01
    case low = 0x02

    public var name: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        case .low: return "Low"
        }
    }
}

public struct NoiseControl: Equatable, Sendable {
    public enum Mode: CaseIterable, Sendable {
        case noiseCanceling
        case ambient
        case off
    }

    public static let ambientLevels = 1...20

    public var isOn: Bool
    public var isAmbient: Bool
    public var focusOnVoice: Bool
    public var ambientLevel: Int
    /// WH-1000XM6: let the headset pick the ambient level from the surroundings.
    public var autoAmbient = false
    public var autoAmbientSensitivity = AutoAmbientSensitivity.standard

    public init(isOn: Bool, isAmbient: Bool, focusOnVoice: Bool, ambientLevel: Int) {
        self.isOn = isOn
        self.isAmbient = isAmbient
        self.focusOnVoice = focusOnVoice
        self.ambientLevel = ambientLevel
    }

    public var mode: Mode {
        get { !isOn ? .off : (isAmbient ? .ambient : .noiseCanceling) }
        set {
            switch newValue {
            case .off: isOn = false
            case .noiseCanceling: isOn = true; isAmbient = false
            case .ambient: isOn = true; isAmbient = true
            }
            if newValue == .ambient && !Self.ambientLevels.contains(ambientLevel) {
                ambientLevel = Self.ambientLevels.upperBound
            }
        }
    }
}

// MARK: - Equalizer

public enum EqualizerLayout: Equatable, Sendable {
    /// WH-1000XM5: Clear Bass plus five bands, -10...+10.
    case fiveBandsWithClearBass
    /// WH-1000XM6: ten bands, -6...+6, no Clear Bass.
    case tenBands

    init?(stepCount: Int) {
        switch stepCount {
        case 6: self = .fiveBandsWithClearBass
        case 10: self = .tenBands
        default: return nil
        }
    }

    public var bandLabels: [String] {
        switch self {
        case .fiveBandsWithClearBass: return ["400", "1k", "2.5k", "6.3k", "16k"]
        case .tenBands: return ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        }
    }

    public var range: ClosedRange<Int> {
        switch self {
        case .fiveBandsWithClearBass: return -10...10
        case .tenBands: return -6...6
        }
    }

    public var hasClearBass: Bool { self == .fiveBandsWithClearBass }

    /// Steps travel as unsigned values offset by the top of the range.
    private var offset: Int { range.upperBound }

    func encode(bands: [Int], clearBass: Int) -> [UInt8] {
        let clamp = { (value: Int) in UInt8(min(max(value, range.lowerBound), range.upperBound) + offset) }
        let padded = (0..<bandLabels.count).map { $0 < bands.count ? bands[$0] : 0 }
        return (hasClearBass ? [clamp(clearBass)] : []) + padded.map(clamp)
    }

    func decode(steps: ArraySlice<UInt8>) -> (bands: [Int], clearBass: Int) {
        let values = steps.map { Int($0) - offset }
        return hasClearBass ? (Array(values.dropFirst()), values[0]) : (values, 0)
    }
}

public struct Equalizer: Equatable, Sendable {
    public static let customPresetID: UInt8 = 0xa0

    public var presetID: UInt8
    public var layout: EqualizerLayout?
    public var bands: [Int]
    public var clearBass: Int

    /// Custom (0xA0) and the user slots (0xA1...0xA5) hold editable band values.
    public var isEditablePreset: Bool { (0xa0...0xa5).contains(presetID) }
}

public struct EqPreset: Identifiable, Hashable, Sendable {
    public var id: UInt8
    public var name: String

    public init(id: UInt8, name: String? = nil) {
        self.id = id
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultName(for: id)
    }

    public static func defaultName(for id: UInt8) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case 0x20: return "Gaming"
        case 0x21...0x23: return "FPS \(id - 0x20)"
        case 0x30: return "Heavy"
        case 0x31: return "Clear"
        case 0x32: return "Hard"
        case 0x33: return "Soft"
        case 0xa0: return "Custom"
        case 0xa1...0xa5: return "User Setting \(id - 0xa0)"
        default: return String(format: "Preset 0x%02X", id)
        }
    }

    /// Used when the device doesn't list its presets.
    public static func fallbackPresets(for layout: EqualizerLayout?) -> [EqPreset] {
        let ids: [UInt8] = layout == .tenBands
            ? [0x30, 0x31, 0x32, 0x33, 0xa0]
            : [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xa0, 0xa1, 0xa2]
        return ids.map { EqPreset(id: $0) }
    }
}

// MARK: - Speak-to-Chat, auto power off

public enum SpeakToChatSensitivity: UInt8, CaseIterable, Sendable {
    case auto = 0x00
    case high = 0x01
    case low = 0x02

    public var name: String {
        switch self {
        case .auto: return "Auto"
        case .high: return "High"
        case .low: return "Low"
        }
    }
}

public enum SpeakToChatTimeout: UInt8, CaseIterable, Sendable {
    case short = 0x00
    case standard = 0x01
    case long = 0x02
    case never = 0x03

    public var name: String {
        switch self {
        case .short: return "Short (~5 s)"
        case .standard: return "Standard (~15 s)"
        case .long: return "Long (~30 s)"
        case .never: return "Don't end automatically"
        }
    }
}

public enum AutoPowerOffOption: UInt8, CaseIterable, Sendable {
    case after5Minutes = 0x00
    case after30Minutes = 0x01
    case after1Hour = 0x02
    case after3Hours = 0x03
    case after15Minutes = 0x04
    case whenTakenOff = 0x10
    case never = 0x11

    public var name: String {
        switch self {
        case .after5Minutes: return "After 5 minutes"
        case .after15Minutes: return "After 15 minutes"
        case .after30Minutes: return "After 30 minutes"
        case .after1Hour: return "After 1 hour"
        case .after3Hours: return "After 3 hours"
        case .whenTakenOff: return "When taken off"
        case .never: return "Never"
        }
    }

    var isTimer: Bool { rawValue <= 0x04 }
}

public struct AutoPowerOff: Equatable, Sendable {
    /// 0x04 (timer only) or 0x05 (timer or wearing detection).
    public var inquiry: UInt8
    public var setting: AutoPowerOffOption

    public init(inquiry: UInt8, setting: AutoPowerOffOption) {
        self.inquiry = inquiry
        self.setting = setting
    }

    /// The second value is the timer the headset falls back to; it must be a timer option.
    var lastTimed: AutoPowerOffOption { setting.isTimer ? setting : .after5Minutes }

    public var options: [AutoPowerOffOption] {
        let timers: [AutoPowerOffOption] = [.after5Minutes, .after30Minutes, .after1Hour, .after3Hours]
        return (inquiry == PowerType.autoPowerOffWearingDetection ? [.whenTakenOff] : []) + timers + [.never]
    }
}

// MARK: - State

public struct HeadphoneState: Equatable, Sendable {
    public var protocolVersion: UInt32?
    public var modelName: String?
    public var firmwareVersion: String?
    /// Raw "support function" ids from the device. Everything the UI shows is gated on these.
    public var supportedFunctions: Set<UInt8> = []

    public var codec: AudioCodec?
    public var battery: Battery?
    public var noise: NoiseControl?
    public var equalizer: Equalizer?
    public var eqPresets: [EqPreset] = []
    public var eqAvailable = true
    public var upscaling: Bool?
    public var speakToChat: Bool?
    public var speakToChatSensitivity: SpeakToChatSensitivity?
    public var speakToChatTimeout: SpeakToChatTimeout?
    public var pauseWhenTakenOff: Bool?
    public var autoPowerOff: AutoPowerOff?

    public init() {}

    public func supports(_ feature: Feature) -> Bool {
        supportedFunctions.contains(feature.rawValue)
    }

    // MARK: Capabilities

    public var batteryInquiry: BatteryInquiry? {
        if supports(.battery) { return .plain }
        if supports(.batteryWithThreshold) { return .withThreshold }
        return nil
    }

    public var noiseVariant: NoiseControlVariant? {
        if supports(.noiseControlNoiseAdaptation) { return .noiseAdaptation }
        if supports(.noiseControlDual) { return .dual }
        if supports(.noiseControlAutoNC) { return .autoNC }
        return nil
    }

    public var eqCapabilityInquiry: UInt8? {
        if supports(.presetEQ) { return 0x00 }
        if supports(.presetEQNonCustomizable) { return 0x02 }
        if supports(.presetEQAndUltMode) { return 0x03 }
        if supports(.presetEQAndErrorCode) { return 0x04 }
        return nil
    }

    public var supportsEqualizer: Bool { eqCapabilityInquiry != nil }

    public var autoPowerOffInquiry: UInt8? {
        if supports(.autoPowerOffWithWearingDetection) { return PowerType.autoPowerOffWearingDetection }
        if supports(.autoPowerOff) { return PowerType.autoPowerOff }
        return nil
    }

    /// Presets offered in the UI: what the device listed, else a per-layout default.
    public var availablePresets: [EqPreset] {
        eqPresets.isEmpty ? EqPreset.fallbackPresets(for: equalizer?.layout) : eqPresets
    }

    /// GET requests to send once the support functions are known.
    public var initialQueries: [[UInt8]] {
        var queries: [[UInt8]] = []
        if supports(.codecIndicator) { queries.append(Request.audioCodec) }
        if let batteryInquiry { queries.append(Request.battery(batteryInquiry)) }
        if let noiseVariant { queries.append(Request.noiseControl(noiseVariant)) }
        if let eqCapabilityInquiry {
            queries += [Request.eqCapability(eqCapabilityInquiry), Request.eqStatus, Request.eqParam]
        }
        if supports(.upscaling) { queries.append(Request.upscaling) }
        if supports(.speakToChat) { queries += [Request.speakToChat, Request.speakToChatConfig] }
        if supports(.pauseWhenTakenOff) { queries.append(Request.pauseWhenTakenOff) }
        if let autoPowerOffInquiry { queries.append(Request.autoPowerOff(autoPowerOffInquiry)) }
        return queries
    }

    /// Cheap periodic refresh; also keeps the link from idling out.
    public var periodicQueries: [[UInt8]] {
        var queries: [[UInt8]] = []
        if let batteryInquiry { queries.append(Request.battery(batteryInquiry)) }
        if supports(.codecIndicator) { queries.append(Request.audioCodec) }
        return queries
    }

    // MARK: Parsing

    /// Folds a RET/NTFY payload into the state. Returns false for payloads this app doesn't track.
    @discardableResult
    public mutating func apply(_ payload: [UInt8]) -> Bool {
        guard let op = payload.first else { return false }
        let p = payload
        switch op {
        case Op.retProtocolInfo:
            guard p.count >= 6 else { return false }
            protocolVersion = UInt32(p[2]) << 24 | UInt32(p[3]) << 16 | UInt32(p[4]) << 8 | UInt32(p[5])
            return true

        case Op.retDeviceInfo:
            guard p.count >= 3 else { return false }
            let length = Int(p[2])
            guard p.count >= 3 + length else { return false }
            let text = String(decoding: p[3..<(3 + length)], as: UTF8.self)
            switch p[1] {
            case DeviceInfoType.modelName: modelName = text
            case DeviceInfoType.firmwareVersion: firmwareVersion = text
            default: return false
            }
            return true

        case Op.retSupportFunction:
            guard p.count >= 3 else { return false }
            let count = Int(p[2])
            guard p.count >= 3 + count * 2 else { return false }
            supportedFunctions = Set(stride(from: 3, to: 3 + count * 2, by: 2).map { p[$0] })
            return true

        case Op.commonRetStatus, Op.commonNtfyStatus:
            guard p.count >= 3, p[1] == CommonType.audioCodec else { return false }
            codec = AudioCodec(rawValue: p[2]) ?? .other
            return true

        case Op.powerRetStatus, Op.powerNtfyStatus:
            guard p.count >= 4, p[1] == PowerType.battery || p[1] == PowerType.batteryWithThreshold else { return false }
            battery = Battery(level: Int(min(p[2], 100)), status: Battery.Status(rawValue: p[3]) ?? .unknown)
            return true

        case Op.powerRetParam, Op.powerNtfyParam:
            guard p.count >= 3,
                  p[1] == PowerType.autoPowerOff || p[1] == PowerType.autoPowerOffWearingDetection,
                  let setting = AutoPowerOffOption(rawValue: p[2]) else { return false }
            autoPowerOff = AutoPowerOff(inquiry: p[1], setting: setting)
            return true

        case Op.ncAsmRetParam, Op.ncAsmNtfyParam:
            return applyNoiseControl(p)

        case Op.eqRetCapability:
            // 51 <type> <bands> <steps> <presetCount> { <id> <nameLength> <name...> }
            guard p.count >= 5 else { return false }
            var presets: [EqPreset] = []
            var index = 5
            for _ in 0..<Int(p[4]) {
                guard index + 1 < p.count else { break }
                let id = p[index], length = Int(p[index + 1])
                guard index + 2 + length <= p.count else { break }
                let name = String(decoding: p[(index + 2)..<(index + 2 + length)], as: UTF8.self)
                presets.append(EqPreset(id: id, name: name))
                index += 2 + length
            }
            eqPresets = presets
            return true

        case Op.eqRetStatus, Op.eqNtfyStatus:
            guard p.count >= 3, p[1] == 0x00 else { return false }
            eqAvailable = p[2] == 0x00
            return true

        case Op.eqRetParam, Op.eqNtfyParam:
            // 57 00 <preset> <stepCount> <steps...>
            guard p.count >= 4, p[1] == 0x00 else { return false }
            let count = Int(p[3])
            guard p.count >= 4 + count else { return false }
            var eq = equalizer ?? Equalizer(presetID: p[2], layout: nil, bands: [], clearBass: 0)
            eq.presetID = p[2]
            if let layout = EqualizerLayout(stepCount: count) {
                (eq.bands, eq.clearBass) = layout.decode(steps: p[4..<(4 + count)])
                eq.layout = layout
            }
            equalizer = eq
            return true

        case Op.audioRetParam, Op.audioNtfyParam:
            guard p.count >= 3, p[1] == AudioType.upscaling else { return false }
            upscaling = p[2] == 0x01
            return true

        case Op.systemRetParam, Op.systemNtfyParam:
            guard p.count >= 3, let on = OnOff.decode(p[2]) else { return false }
            switch p[1] {
            case SystemType.pauseWhenTakenOff: pauseWhenTakenOff = on
            case SystemType.speakToChat: speakToChat = on
            default: return false
            }
            return true

        case Op.systemRetExtParam, Op.systemNtfyExtParam:
            guard p.count >= 4, p[1] == SystemType.speakToChat else { return false }
            speakToChatSensitivity = SpeakToChatSensitivity(rawValue: p[2])
            speakToChatTimeout = SpeakToChatTimeout(rawValue: p[3])
            return true

        default:
            return false
        }
    }

    private mutating func applyNoiseControl(_ p: [UInt8]) -> Bool {
        // 67 <variant> <valueChangeStatus> <on> <0=NC 1=ambient> <focus on voice> <level> [<auto ambient> <sensitivity>]
        guard p.count >= 7, let variant = NoiseControlVariant(rawValue: p[1]) else { return false }
        var noise = NoiseControl(isOn: p[3] == 0x01, isAmbient: p[4] == 0x01, focusOnVoice: p[5] == 0x01, ambientLevel: Int(p[6]))
        if variant == .noiseAdaptation {
            guard p.count >= 9 else { return false }
            noise.autoAmbient = p[7] == 0x01
            noise.autoAmbientSensitivity = AutoAmbientSensitivity(rawValue: p[8]) ?? .standard
        }
        self.noise = noise
        return true
    }
}
