import Foundation

/// A byte pipe to the headphones (an RFCOMM channel in the app, a mock in tests).
@MainActor
public protocol MDRTransport: AnyObject {
    func write(_ bytes: [UInt8])
    func close()
}

public enum MDRSessionError: LocalizedError, Equatable {
    case closed
    case noAck
    case noReply(command: UInt8)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The connection to the headphones is closed."
        case .noAck: return "The headphones did not acknowledge a command."
        case .noReply(let command): return String(format: "The headphones did not answer request 0x%02x.", command)
        }
    }
}

/// Speaks the MDR link layer on top of a transport.
///
/// * Every frame we send carries a 1-bit sequence number. The device answers with an ACK whose sequence
///   number is the next one to use, and only one command may be waiting for its ACK at a time.
/// * Every data frame the device sends must be ACKed with `1 - seq`, or the device keeps re-sending it.
@MainActor
public final class MDRSession {
    /// Called for every data frame from the device (replies and unsolicited notifications alike).
    public var onMessage: ((MDRDataType, [UInt8]) -> Void)?
    /// Called once when the session closes, with the error that closed it (nil for a local close).
    public var onClose: ((Error?) -> Void)?
    public var log: ((String) -> Void)?

    public var ackTimeout: Duration = .milliseconds(1500)
    public var maxAttempts = 2
    public private(set) var isClosed = false

    private let transport: MDRTransport
    private var parser = MDRFrameParser()
    private var sequence: UInt8 = 0
    private var outbox: [Outgoing] = []
    private var inFlight: Outgoing?
    private var ackTimer: Task<Void, Never>?
    private var replyWaiters: [ReplyWaiter] = []

    private struct Outgoing {
        let id = UUID()
        let type: MDRDataType
        let payload: [UInt8]
        let completion: (Error?) -> Void
        var attempts = 0
    }

    private struct ReplyWaiter {
        let id: UUID
        let command: UInt8
        let subtype: UInt8?
        let continuation: CheckedContinuation<[UInt8], Error>
    }

    public init(transport: MDRTransport) {
        self.transport = transport
    }

    /// Feed bytes read from the transport.
    public func receive<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for result in parser.feed(bytes) {
            switch result {
            case .success(let frame): handle(frame)
            case .failure(let error): log?("dropped malformed frame: \(error)")
            }
        }
    }

    /// Queues a command; commands go out in the order they were enqueued. `completion` runs once the
    /// device has ACKed it, or with the error that stopped it.
    public func enqueue(_ payload: [UInt8], type: MDRDataType = .command, completion: ((Error?) -> Void)? = nil) {
        guard !isClosed else {
            completion?(MDRSessionError.closed)
            return
        }
        outbox.append(Outgoing(type: type, payload: payload, completion: completion ?? { _ in }))
        pump()
    }

    /// Sends a command and returns once the device has ACKed it.
    public func send(_ payload: [UInt8], type: MDRDataType = .command) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(payload, type: type) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Sends a command and waits for the reply whose first byte is `reply` (and second byte `subtype`, if given).
    public func request(
        _ payload: [UInt8],
        reply: UInt8,
        subtype: UInt8? = nil,
        type: MDRDataType = .command,
        timeout: Duration = .seconds(3)
    ) async throws -> [UInt8] {
        guard !isClosed else { throw MDRSessionError.closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            replyWaiters.append(ReplyWaiter(id: id, command: reply, subtype: subtype, continuation: continuation))
            Task {
                do {
                    try await self.send(payload, type: type)
                } catch {
                    self.failWaiter(id, with: error)
                    return
                }
                try? await Task.sleep(for: timeout)
                self.failWaiter(id, with: MDRSessionError.noReply(command: payload.first ?? 0))
            }
        }
    }

    public func close() {
        shutDown(error: nil, closeTransport: true)
    }

    /// The transport went away underneath us.
    public func transportDidClose(error: Error?) {
        shutDown(error: error ?? MDRSessionError.closed, closeTransport: false)
    }

    // MARK: - Internals

    private func handle(_ frame: MDRFrame) {
        if frame.type == .ack {
            handleAck(frame.sequence)
            return
        }

        transport.write(MDRFrame(type: .ack, sequence: 1 &- frame.sequence & 1).encoded())
        guard !frame.payload.isEmpty else { return }
        log?("← \(frame.type) \(frame.payload.hexString)")

        onMessage?(frame.type, frame.payload)

        if let index = replyWaiters.firstIndex(where: { waiter in
            waiter.command == frame.payload[0]
                && (waiter.subtype == nil || (frame.payload.count > 1 && frame.payload[1] == waiter.subtype))
        }) {
            replyWaiters.remove(at: index).continuation.resume(returning: frame.payload)
        }
    }

    private func handleAck(_ ackSequence: UInt8) {
        guard let current = inFlight else {
            log?("unexpected ACK \(ackSequence)")
            return
        }
        let expected = 1 &- sequence & 1
        if ackSequence != expected {
            log?("ACK carried seq \(ackSequence), expected \(expected)")
        }
        sequence = expected
        ackTimer?.cancel()
        ackTimer = nil
        inFlight = nil
        current.completion(nil)
        pump()
    }

    private func pump() {
        guard inFlight == nil, !isClosed, !outbox.isEmpty else { return }
        inFlight = outbox.removeFirst()
        transmitInFlight()
    }

    private func transmitInFlight() {
        guard var current = inFlight else { return }
        current.attempts += 1
        inFlight = current
        log?("→ \(current.type) \(current.payload.hexString)")
        transport.write(MDRFrame(type: current.type, sequence: sequence, payload: current.payload).encoded())

        let id = current.id
        let timeout = ackTimeout
        ackTimer?.cancel()
        ackTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.ackTimedOut(id)
        }
    }

    private func ackTimedOut(_ id: UUID) {
        guard let current = inFlight, current.id == id else { return }
        if current.attempts < maxAttempts {
            log?(String(format: "no ACK for 0x%02x, resending", current.payload.first ?? 0))
            transmitInFlight()
        } else {
            inFlight = nil
            current.completion(MDRSessionError.noAck)
            pump()
        }
    }

    private func failWaiter(_ id: UUID, with error: Error) {
        guard let index = replyWaiters.firstIndex(where: { $0.id == id }) else { return }
        replyWaiters.remove(at: index).continuation.resume(throwing: error)
    }

    private func shutDown(error: Error?, closeTransport: Bool) {
        guard !isClosed else { return }
        isClosed = true
        ackTimer?.cancel()
        ackTimer = nil

        let pending = (inFlight.map { [$0] } ?? []) + outbox
        inFlight = nil
        outbox.removeAll()
        pending.forEach { $0.completion(MDRSessionError.closed) }

        let waiters = replyWaiters
        replyWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: MDRSessionError.closed) }

        if closeTransport { transport.close() }
        onClose?(error)
    }
}

extension Array where Element == UInt8 {
    /// "68 17 01 ..." for logs.
    public var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
