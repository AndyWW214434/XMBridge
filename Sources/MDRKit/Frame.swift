// Wire framing for Sony's MDR headphone protocol.
//
//   0x3e  ESCAPE( type | seq | length:UInt32BE | payload | checksum )  0x3c
//
// The checksum is the 8-bit sum of every unescaped byte from `type` to the end of the payload.
// 0x3c, 0x3d and 0x3e inside the frame are escaped as 0x3d followed by the byte with bit 4 cleared.

import Foundation

public struct MDRDataType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let ack = MDRDataType(rawValue: 0x01)
    /// "DATA_MDR": the command set this app speaks (table 1).
    public static let command = MDRDataType(rawValue: 0x0c)
    /// "DATA_MDR_NO2": the secondary command set (table 2: voice guidance, pairing, ...).
    public static let command2 = MDRDataType(rawValue: 0x0e)

    public var description: String {
        switch self {
        case .ack: return "ACK"
        case .command: return "MDR"
        case .command2: return "MDR2"
        default: return String(format: "0x%02x", rawValue)
        }
    }
}

public enum MDRFrameError: Error, Equatable {
    case badEscape
    case tooShort
    case lengthMismatch
    case badChecksum
}

public struct MDRFrame: Equatable, Sendable {
    public var type: MDRDataType
    public var sequence: UInt8
    public var payload: [UInt8]

    static let startMarker: UInt8 = 0x3e
    static let endMarker: UInt8 = 0x3c
    static let escapeMarker: UInt8 = 0x3d

    public init(type: MDRDataType, sequence: UInt8, payload: [UInt8] = []) {
        self.type = type
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded() -> [UInt8] {
        let length = UInt32(payload.count)
        var body: [UInt8] = [type.rawValue, sequence]
        body += [UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                 UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)]
        body += payload
        body.append(Self.checksum(body))

        var out: [UInt8] = [Self.startMarker]
        out.reserveCapacity(body.count + 4)
        for byte in body {
            if byte == Self.startMarker || byte == Self.endMarker || byte == Self.escapeMarker {
                out += [Self.escapeMarker, byte & 0xef]
            } else {
                out.append(byte)
            }
        }
        out.append(Self.endMarker)
        return out
    }

    /// Decodes the escaped bytes found between a start and an end marker.
    public init<Bytes: Collection>(decoding escaped: Bytes) throws where Bytes.Element == UInt8 {
        var raw: [UInt8] = []
        raw.reserveCapacity(escaped.count)
        var iterator = escaped.makeIterator()
        while let byte = iterator.next() {
            if byte == Self.escapeMarker {
                guard let next = iterator.next(), (0x2c...0x2e).contains(next) else { throw MDRFrameError.badEscape }
                raw.append(next | 0x10)
            } else {
                raw.append(byte)
            }
        }

        guard raw.count >= 7 else { throw MDRFrameError.tooShort }
        let length = Int(raw[2]) << 24 | Int(raw[3]) << 16 | Int(raw[4]) << 8 | Int(raw[5])
        guard raw.count == 7 + length else { throw MDRFrameError.lengthMismatch }
        guard Self.checksum(raw[0..<(6 + length)]) == raw[6 + length] else { throw MDRFrameError.badChecksum }

        self.type = MDRDataType(rawValue: raw[0])
        self.sequence = raw[1]
        self.payload = Array(raw[6..<(6 + length)])
    }

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt8 where Bytes.Element == UInt8 {
        bytes.reduce(0, &+)
    }
}

/// Reassembles frames from an RFCOMM byte stream: a read can hold part of a frame or several frames.
public struct MDRFrameParser {
    private var buffer: [UInt8] = []
    private var inFrame = false
    private let maxFrameSize = 4096

    public init() {}

    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [Result<MDRFrame, Error>] where Bytes.Element == UInt8 {
        var results: [Result<MDRFrame, Error>] = []
        for byte in bytes {
            if byte == MDRFrame.startMarker {
                // A start marker always begins a new frame; anything half-read before it is garbage.
                buffer.removeAll(keepingCapacity: true)
                inFrame = true
            } else if byte == MDRFrame.endMarker && inFrame {
                let body = buffer
                results.append(Result { try MDRFrame(decoding: body) })
                buffer.removeAll(keepingCapacity: true)
                inFrame = false
            } else if inFrame {
                buffer.append(byte)
                if buffer.count > maxFrameSize {
                    buffer.removeAll(keepingCapacity: true)
                    inFrame = false
                }
            }
        }
        return results
    }
}
