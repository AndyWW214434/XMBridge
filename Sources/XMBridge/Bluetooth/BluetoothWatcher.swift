import IOBluetooth

/// Reports Bluetooth devices connecting to the Mac, so the app can attach when the headphones turn on.
@MainActor
final class BluetoothWatcher: NSObject {
    var onDeviceConnected: ((IOBluetoothDevice) -> Void)?
    private var registration: IOBluetoothUserNotification?

    func start() {
        guard registration == nil else { return }
        registration = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    @objc private nonisolated func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        MainActor.assumeIsolated { onDeviceConnected?(device) }
    }
}
