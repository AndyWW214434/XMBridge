import Testing
@testable import MDRKit

@MainActor
final class MockTransport: MDRTransport {
    var written: [MDRFrame] = []
    var closed = false

    func write(_ bytes: [UInt8]) {
        var parser = MDRFrameParser()
        written += parser.feed(bytes).compactMap { try? $0.get() }
    }

    func close() { closed = true }
}

@MainActor
@Suite struct SessionTests {
    /// Lets queued tasks on the main actor run.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func sendWaitsForAckAndAdvancesSequence() async throws {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)

        async let first: Void = session.send([0x22, 0x00])
        await settle()
        #expect(transport.written.last == MDRFrame(type: .command, sequence: 0, payload: [0x22, 0x00]))
        session.receive(MDRFrame(type: .ack, sequence: 1).encoded())
        try await first

        async let second: Void = session.send([0x12, 0x02])
        await settle()
        #expect(transport.written.last?.sequence == 1)
        session.receive(MDRFrame(type: .ack, sequence: 0).encoded())
        try await second
    }

    @Test func onlyOneCommandInFlight() async throws {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)

        async let a: Void = session.send([0x01])
        async let b: Void = session.send([0x02])
        await settle()
        #expect(transport.written.count == 1)
        session.receive(MDRFrame(type: .ack, sequence: 1).encoded())
        await settle()
        #expect(transport.written.count == 2)
        session.receive(MDRFrame(type: .ack, sequence: 0).encoded())
        _ = try await (a, b)
    }

    @Test func acksDeviceDataAndDeliversIt() async {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)
        var received: [[UInt8]] = []
        session.onMessage = { _, payload in received.append(payload) }

        session.receive(MDRFrame(type: .command, sequence: 0, payload: [0x69, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14]).encoded())
        #expect(transport.written == [MDRFrame(type: .ack, sequence: 1)])
        #expect(received == [[0x69, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14]])
    }

    @Test func requestReturnsMatchingReply() async throws {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)

        async let reply = session.request(Request.firmwareVersion, reply: 0x05, subtype: 0x02)
        await settle()
        session.receive(MDRFrame(type: .ack, sequence: 1).encoded())
        // An unrelated notification first, then the reply.
        session.receive(MDRFrame(type: .command, sequence: 0, payload: [0x25, 0x00, 0x32, 0x00]).encoded())
        session.receive(MDRFrame(type: .command, sequence: 1, payload: [0x05, 0x02, 0x01, 0x31]).encoded())
        let value = try await reply
        #expect(value == [0x05, 0x02, 0x01, 0x31])
    }

    @Test func resendsThenFailsWithoutAck() async {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)
        session.ackTimeout = .milliseconds(20)

        await #expect(throws: MDRSessionError.noAck) {
            try await session.send([0x22, 0x00])
        }
        #expect(transport.written.count == 2)
        #expect(transport.written.allSatisfy { $0.sequence == 0 })
    }

    @Test func closeFailsPendingWork() async {
        let transport = MockTransport()
        let session = MDRSession(transport: transport)
        var closeCount = 0
        session.onClose = { _ in closeCount += 1 }

        async let pending: Void = session.send([0x22, 0x00])
        await settle()
        session.close()
        do {
            try await pending
            Issue.record("send should have failed")
        } catch {
            #expect(error as? MDRSessionError == .closed)
        }
        #expect(transport.closed)
        #expect(closeCount == 1)
    }
}
