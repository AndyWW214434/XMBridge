// The "MDR v2, table 1" command set spoken by the WH-1000XM5 and WH-1000XM6.
//
// Byte layouts follow the reverse-engineering in mos9527/SonyHeadphonesClient (libmdr, MIT), cross-checked
// against Gadgetbridge's Sony implementation and AmitRajput-Dev/SonyBridge.

public enum MDR {
    /// SDP service UUID of the v2 protocol's RFCOMM service (956C7B26-D49A-4BA8-B03F-B17D393CB6E2).
    public static let serviceUUID: [UInt8] = [
        0x95, 0x6c, 0x7b, 0x26, 0xd4, 0x9a, 0x4b, 0xa8,
        0xb0, 0x3f, 0xb1, 0x7d, 0x39, 0x3c, 0xb6, 0xe2,
    ]
}

/// First payload byte of a table-1 message. GET/RET/SET/NTFY come in families that share a sub-type byte.
public enum Op {
    public static let getProtocolInfo: UInt8 = 0x00
    public static let retProtocolInfo: UInt8 = 0x01
    public static let getDeviceInfo: UInt8 = 0x04
    public static let retDeviceInfo: UInt8 = 0x05
    public static let getSupportFunction: UInt8 = 0x06
    public static let retSupportFunction: UInt8 = 0x07

    public static let commonGetStatus: UInt8 = 0x12
    public static let commonRetStatus: UInt8 = 0x13
    public static let commonNtfyStatus: UInt8 = 0x15

    public static let powerGetStatus: UInt8 = 0x22
    public static let powerRetStatus: UInt8 = 0x23
    public static let powerSetStatus: UInt8 = 0x24
    public static let powerNtfyStatus: UInt8 = 0x25
    public static let powerGetParam: UInt8 = 0x26
    public static let powerRetParam: UInt8 = 0x27
    public static let powerSetParam: UInt8 = 0x28
    public static let powerNtfyParam: UInt8 = 0x29

    public static let eqGetCapability: UInt8 = 0x50
    public static let eqRetCapability: UInt8 = 0x51
    public static let eqGetStatus: UInt8 = 0x52
    public static let eqRetStatus: UInt8 = 0x53
    public static let eqNtfyStatus: UInt8 = 0x55
    public static let eqGetParam: UInt8 = 0x56
    public static let eqRetParam: UInt8 = 0x57
    public static let eqSetParam: UInt8 = 0x58
    public static let eqNtfyParam: UInt8 = 0x59

    public static let ncAsmGetParam: UInt8 = 0x66
    public static let ncAsmRetParam: UInt8 = 0x67
    public static let ncAsmSetParam: UInt8 = 0x68
    public static let ncAsmNtfyParam: UInt8 = 0x69

    public static let audioGetParam: UInt8 = 0xe6
    public static let audioRetParam: UInt8 = 0xe7
    public static let audioSetParam: UInt8 = 0xe8
    public static let audioNtfyParam: UInt8 = 0xe9

    public static let systemGetParam: UInt8 = 0xf6
    public static let systemRetParam: UInt8 = 0xf7
    public static let systemSetParam: UInt8 = 0xf8
    public static let systemNtfyParam: UInt8 = 0xf9
    public static let systemGetExtParam: UInt8 = 0xfa
    public static let systemRetExtParam: UInt8 = 0xfb
    public static let systemSetExtParam: UInt8 = 0xfc
    public static let systemNtfyExtParam: UInt8 = 0xfd
}

/// "Support function" ids the device advertises in its RET_SUPPORT_FUNCTION reply. Only the ones this app uses.
public enum Feature: UInt8, CaseIterable, Sendable {
    case codecIndicator = 0x12
    case battery = 0x20
    case powerOff = 0x23
    case autoPowerOff = 0x24
    case autoPowerOffWithWearingDetection = 0x25
    case batteryWithThreshold = 0x28
    case presetEQ = 0x50
    case presetEQNonCustomizable = 0x52
    case presetEQAndUltMode = 0x53
    case presetEQAndErrorCode = 0x57
    /// Noise control family using sub-type 0x15.
    case noiseControlAutoNC = 0x68
    /// Noise control family using sub-type 0x17 (WH-1000XM5).
    case noiseControlDual = 0x6b
    /// Noise control family using sub-type 0x19, with automatic ambient sound (WH-1000XM6).
    case noiseControlNoiseAdaptation = 0x6d
    /// DSEE / DSEE Extreme, on or "auto".
    case upscaling = 0xe2
    case pauseWhenTakenOff = 0xf1
    case speakToChat = 0xfc
}

enum DeviceInfoType {
    static let modelName: UInt8 = 0x01
    static let firmwareVersion: UInt8 = 0x02
}

enum PowerType {
    static let battery: UInt8 = 0x00
    static let powerOff: UInt8 = 0x03
    static let autoPowerOff: UInt8 = 0x04
    static let autoPowerOffWearingDetection: UInt8 = 0x05
    static let batteryWithThreshold: UInt8 = 0x08
}

enum SystemType {
    static let pauseWhenTakenOff: UInt8 = 0x01
    static let speakToChat: UInt8 = 0x0c
}

enum AudioType {
    static let upscaling: UInt8 = 0x01
}

enum CommonType {
    static let audioCodec: UInt8 = 0x02
}

/// The protocol's own on/off encoding for system settings: 0x00 is ON.
enum OnOff {
    static func encode(_ on: Bool) -> UInt8 { on ? 0x00 : 0x01 }
    static func decode(_ byte: UInt8) -> Bool? {
        switch byte {
        case 0x00: return true
        case 0x01: return false
        default: return nil
        }
    }
}

/// Builders for the payloads this app sends.
public enum Request {
    public static let protocolInfo: [UInt8] = [Op.getProtocolInfo, 0x00]
    public static let modelName: [UInt8] = [Op.getDeviceInfo, DeviceInfoType.modelName]
    public static let firmwareVersion: [UInt8] = [Op.getDeviceInfo, DeviceInfoType.firmwareVersion]
    public static let supportFunctions: [UInt8] = [Op.getSupportFunction, 0x00]
    public static let audioCodec: [UInt8] = [Op.commonGetStatus, CommonType.audioCodec]
    public static let eqStatus: [UInt8] = [Op.eqGetStatus, 0x00]
    public static let eqParam: [UInt8] = [Op.eqGetParam, 0x00]
    public static let upscaling: [UInt8] = [Op.audioGetParam, AudioType.upscaling]
    public static let speakToChat: [UInt8] = [Op.systemGetParam, SystemType.speakToChat]
    public static let speakToChatConfig: [UInt8] = [Op.systemGetExtParam, SystemType.speakToChat]
    public static let pauseWhenTakenOff: [UInt8] = [Op.systemGetParam, SystemType.pauseWhenTakenOff]
    public static let powerOff: [UInt8] = [Op.powerSetStatus, PowerType.powerOff, 0x01]

    public static func battery(_ inquiry: BatteryInquiry) -> [UInt8] {
        [Op.powerGetStatus, inquiry.rawValue]
    }

    public static func noiseControl(_ variant: NoiseControlVariant) -> [UInt8] {
        [Op.ncAsmGetParam, variant.rawValue]
    }

    /// `adjusting` is true while the user is still dragging the ambient level slider.
    public static func setNoiseControl(_ noise: NoiseControl, variant: NoiseControlVariant, adjusting: Bool = false) -> [UInt8] {
        var payload: [UInt8] = [
            Op.ncAsmSetParam,
            variant.rawValue,
            adjusting ? 0x00 : 0x01,
            noise.isOn ? 0x01 : 0x00,
            noise.isAmbient ? 0x01 : 0x00,
            noise.focusOnVoice ? 0x01 : 0x00,
            UInt8(clamping: noise.ambientLevel),
        ]
        if variant == .noiseAdaptation {
            payload += [noise.autoAmbient ? 0x01 : 0x00, noise.autoAmbientSensitivity.rawValue]
        }
        return payload
    }

    public static func eqCapability(_ inquiry: UInt8) -> [UInt8] {
        [Op.eqGetCapability, inquiry, 0x01 /* English preset names */]
    }

    public static func selectEqPreset(_ id: UInt8) -> [UInt8] {
        [Op.eqSetParam, 0x00, id, 0x00]
    }

    public static func setEqBands(_ eq: Equalizer) -> [UInt8] {
        let steps = eq.layout?.encode(bands: eq.bands, clearBass: eq.clearBass) ?? []
        return [Op.eqSetParam, 0x00, eq.presetID, UInt8(steps.count)] + steps
    }

    public static func setUpscaling(_ on: Bool) -> [UInt8] {
        // UpscalingTypeAutoOff: 0x00 = off, 0x01 = auto.
        [Op.audioSetParam, AudioType.upscaling, on ? 0x01 : 0x00]
    }

    public static func setSpeakToChat(_ on: Bool) -> [UInt8] {
        // Last byte is the "preview mode" flag, which stays off.
        [Op.systemSetParam, SystemType.speakToChat, OnOff.encode(on), OnOff.encode(false)]
    }

    public static func setSpeakToChatConfig(sensitivity: SpeakToChatSensitivity, timeout: SpeakToChatTimeout) -> [UInt8] {
        [Op.systemSetExtParam, SystemType.speakToChat, sensitivity.rawValue, timeout.rawValue]
    }

    public static func setPauseWhenTakenOff(_ on: Bool) -> [UInt8] {
        [Op.systemSetParam, SystemType.pauseWhenTakenOff, OnOff.encode(on)]
    }

    public static func autoPowerOff(_ inquiry: UInt8) -> [UInt8] {
        [Op.powerGetParam, inquiry]
    }

    public static func setAutoPowerOff(_ value: AutoPowerOff) -> [UInt8] {
        [Op.powerSetParam, value.inquiry, value.setting.rawValue, value.lastTimed.rawValue]
    }
}
