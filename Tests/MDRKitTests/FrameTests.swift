import Testing
@testable import MDRKit

@Suite struct FrameTests {
    @Test func encodesProtocolInfoRequest() {
        let frame = MDRFrame(type: .command, sequence: 0, payload: Request.protocolInfo)
        // 0c 00 | 00 00 00 02 | 00 00 | checksum 0x0e
        #expect(frame.encoded() == [0x3e, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x0e, 0x3c])
    }

    @Test func encodesBareAck() {
        let frame = MDRFrame(type: .ack, sequence: 1)
        #expect(frame.encoded() == [0x3e, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x3c])
    }

    @Test func escapesMarkerBytesAndRoundTrips() throws {
        let frame = MDRFrame(type: .command, sequence: 1, payload: [0x3c, 0x3d, 0x3e, 0x00, 0xff])
        let encoded = frame.encoded()
        let body = encoded.dropFirst().dropLast()
        #expect(!body.contains(0x3c) && !body.contains(0x3e))
        #expect(try MDRFrame(decoding: body) == frame)
    }

    @Test func rejectsBadChecksum() {
        var encoded = MDRFrame(type: .command, sequence: 0, payload: [0x22, 0x00]).encoded()
        encoded[encoded.count - 2] &+= 1
        #expect(throws: MDRFrameError.badChecksum) {
            try MDRFrame(decoding: encoded.dropFirst().dropLast())
        }
    }

    @Test func parserReassemblesSplitAndBatchedFrames() throws {
        let a = MDRFrame(type: .ack, sequence: 1)
        let b = MDRFrame(type: .command, sequence: 0, payload: [0x23, 0x00, 0x50, 0x00])
        let stream = [0x00, 0x11] + a.encoded() + b.encoded()

        var parser = MDRFrameParser()
        var frames: [MDRFrame] = []
        for chunk in [stream[0..<5], stream[5..<12], stream[12...]] {
            frames += try parser.feed(chunk).map { try $0.get() }
        }
        #expect(frames == [a, b])
    }
}
