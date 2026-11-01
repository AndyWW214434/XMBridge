import Foundation
import IOBluetooth
import MDRKit

/// A paired headset that exposes Sony's v2 control service.
struct PairedHeadphones: Identifiable, Hashable {
    let address: String
    let name: String
    let isConnected: Bool

    var id: String { address }

    /// Paired devices that look like Sony v2 headphones, connected ones first.
    static func all() -> [PairedHeadphones] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices
            .filter(RFCOMMTransport.looksLikeSonyV2)
            .compactMap { device in
                guard let address = device.addressString else { return nil }
                return PairedHeadphones(address: address, name: device.name ?? address, isConnected: device.isConnected())
            }
            .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
    }
}

enum TransportError: LocalizedError {
    case deviceNotFound
    case serviceNotFound
    case noChannel
    case openFailed(IOReturn)
    case timedOut
    case disconnected

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "The headphones aren't paired with this Mac."
        case .serviceNotFound:
            return "The headphones don't expose Sony's control service. Make sure they're a supported model and connected."
        case .noChannel:
            return "Couldn't find the control channel on the headphones."
        case .openFailed(let status):
            return String(format: "Couldn't open the control channel (0x%08x). Are the headphones on and connected?", status)
        case .timedOut:
            return "The headphones didn't respond. Turn them on, connect them in Bluetooth settings, and try again."
        case .disconnected:
            return "The headphones disconnected."
        }
    }
}

/// RFCOMM channel to the headset's Sony control service. IOBluetooth delivers its callbacks on the run loop
/// the channel was opened from, which is the main one here.
@MainActor
final class RFCOMMTransport: NSObject, MDRTransport {
    var onReceive: (([UInt8]) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var sdpContinuation: CheckedContinuation<Void, Never>?
    private var isClosed = false

    private nonisolated static var serviceUUID: IOBluetoothSDPUUID {
        var bytes = MDR.serviceUUID
        return IOBluetoothSDPUUID(bytes: &bytes, length: bytes.count)
    }

    nonisolated static func looksLikeSonyV2(_ device: IOBluetoothDevice) -> Bool {
        if device.getServiceRecord(for: serviceUUID) != nil { return true }
        let name = device.name ?? ""
        return name.contains("WH-1000XM5") || name.contains("WH-1000XM6")
    }

    private init(device: IOBluetoothDevice) {
        self.device = device
    }

    static func open(address: String) async throws -> RFCOMMTransport {
        guard let device = IOBluetoothDevice(addressString: address) else { throw TransportError.deviceNotFound }
        let transport = RFCOMMTransport(device: device)
        try await transport.openChannel()
        return transport
    }

    func write(_ bytes: [UInt8]) {
        guard let channel, !isClosed else { return }
        let mtu = max(1, Int(channel.getMTU()))
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
            let status = channel.writeSync(&chunk, length: UInt16(chunk.count))
            if status != kIOReturnSuccess {
                finish(error: TransportError.openFailed(status))
                return
            }
            offset += chunk.count
        }
    }

    func close() {
        finish(error: nil)
    }

    // MARK: - Opening

    private func openChannel() async throws {
        if device.getServiceRecord(for: Self.serviceUUID) == nil {
            await refreshServiceRecords()
        }
        guard let record = device.getServiceRecord(for: Self.serviceUUID) else { throw TransportError.serviceNotFound }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { throw TransportError.noChannel }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            var opened: IOBluetoothRFCOMMChannel?
            // Opens the baseband link too if the headset is on but not currently connected.
            let status = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
            if status != kIOReturnSuccess {
                resumeOpen(throwing: TransportError.openFailed(status))
                return
            }
            channel = opened
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.resumeOpen(throwing: TransportError.timedOut)
            }
        }
    }

    private func resumeOpen(throwing error: Error?) {
        guard let continuation = openContinuation else { return }
        openContinuation = nil
        if let error {
            _ = channel?.setDelegate(nil)
            _ = channel?.close()
            channel = nil
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Re-runs SDP when the cached service records don't include the control service.
    private func refreshServiceRecords() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sdpContinuation = continuation
            if device.performSDPQuery(self, uuids: [Self.serviceUUID]) != kIOReturnSuccess {
                resumeSDP()
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.resumeSDP()
            }
        }
    }

    private func resumeSDP() {
        sdpContinuation?.resume()
        sdpContinuation = nil
    }

    private func finish(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        _ = channel?.setDelegate(nil)
        _ = channel?.close()
        channel = nil
        onClose?(error)
    }

    // MARK: - IOBluetooth callbacks (delivered on the main run loop)

    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { resumeSDP() }
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            resumeOpen(throwing: error == kIOReturnSuccess ? nil : TransportError.openFailed(error))
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { onReceive?(bytes) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated {
            if openContinuation != nil {
                resumeOpen(throwing: TransportError.timedOut)
            }
            finish(error: TransportError.disconnected)
        }
    }
}
