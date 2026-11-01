import Foundation
import IOBluetooth
import MDRKit

/// Owns the connection to one headset and exposes its settings to SwiftUI.
///
/// Setters update `state` right away so the UI responds instantly; the headset then answers with
/// notifications that `HeadphoneState.apply` folds back in, which also catches changes made on the headset.
@MainActor
final class HeadphoneController: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting(name: String)
        case connected
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var state = HeadphoneState()
    @Published private(set) var devices: [PairedHeadphones] = []
    @Published private(set) var connectedDevice: PairedHeadphones?
    @Published var errorMessage: String?
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Keys.autoConnect) }
    }

    private var session: MDRSession?
    private var connectTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var lastAdjustingSend = Date.distantPast
    private let watcher = BluetoothWatcher()

    private enum Keys {
        static let autoConnect = "autoConnect"
        static let lastDevice = "lastDeviceAddress"
    }

    private var rememberedAddress: String? {
        get { UserDefaults.standard.string(forKey: Keys.lastDevice) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastDevice) }
    }

    init() {
        autoConnect = UserDefaults.standard.object(forKey: Keys.autoConnect) as? Bool ?? true
        refreshDevices()
        watcher.onDeviceConnected = { [weak self] device in self?.deviceDidConnect(device) }
        watcher.start()
        if autoConnect, let device = devices.first(where: { $0.isConnected && isPreferred($0.address) }) {
            connect(device)
        }
        #if DEBUG
        DemoMode.startIfRequested(self)
        #endif
    }

    #if DEBUG
    /// Shows `state` as if a headset were connected; setters then only update the UI.
    func showDemo(_ state: HeadphoneState) {
        connectTask?.cancel()
        tearDown()
        self.state = state
        phase = .connected
    }
    #endif

    var isConnected: Bool { phase == .connected }

    var displayName: String {
        state.modelName ?? connectedDevice?.name ?? "Headphones"
    }

    // MARK: - Connection

    func refreshDevices() {
        devices = PairedHeadphones.all()
    }

    func connect(_ device: PairedHeadphones) {
        connectTask?.cancel()
        tearDown()
        errorMessage = nil
        phase = .connecting(name: device.name)
        connectTask = Task { await establish(device) }
    }

    func disconnect() {
        connectTask?.cancel()
        tearDown()
        phase = .disconnected
    }

    private func establish(_ device: PairedHeadphones) async {
        do {
            let transport = try await RFCOMMTransport.open(address: device.address)
            guard !Task.isCancelled else {
                transport.close()
                return
            }

            let session = MDRSession(transport: transport)
            transport.onReceive = { [weak session] bytes in session?.receive(bytes) }
            transport.onClose = { [weak session] error in session?.transportDidClose(error: error) }
            session.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
            session.onClose = { [weak self, weak session] error in self?.sessionDidClose(session, error: error) }
            #if DEBUG
            session.log = { NSLog("[mdr] %@", $0) }
            #endif

            self.session = session
            state = HeadphoneState()
            try await handshake(session)
            guard !Task.isCancelled else { return }

            connectedDevice = device
            rememberedAddress = device.address
            phase = .connected
            startPolling()
        } catch {
            guard !Task.isCancelled else { return }
            tearDown()
            phase = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    private func handshake(_ session: MDRSession) async throws {
        _ = try await session.request(Request.protocolInfo, reply: Op.retProtocolInfo)
        _ = try? await session.request(Request.modelName, reply: Op.retDeviceInfo, subtype: Request.modelName[1])
        _ = try? await session.request(Request.firmwareVersion, reply: Op.retDeviceInfo, subtype: Request.firmwareVersion[1])
        _ = try await session.request(Request.supportFunctions, reply: Op.retSupportFunction)
        // Replies to these arrive as regular messages and land in `state` through `handle`.
        state.initialQueries.forEach { session.enqueue($0) }
    }

    private func handle(_ type: MDRDataType, _ payload: [UInt8]) {
        guard type == .command else { return }
        state.apply(payload)
    }

    private func sessionDidClose(_ closed: MDRSession?, error: Error?) {
        guard let closed, closed === session else { return }
        tearDown()
        phase = .disconnected
        if error != nil {
            errorMessage = "The headphones disconnected."
        }
    }

    private func tearDown() {
        pollTask?.cancel()
        pollTask = nil
        if let session {
            session.onClose = nil
            session.close()
        }
        session = nil
        connectedDevice = nil
        state = HeadphoneState()
    }

    /// Battery and codec don't always send notifications; polling also keeps the link from idling out.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let session = self.session else { return }
                self.state.periodicQueries.forEach { session.enqueue($0) }
            }
        }
    }

    private func isPreferred(_ address: String) -> Bool {
        rememberedAddress == nil || rememberedAddress == address
    }

    private func deviceDidConnect(_ device: IOBluetoothDevice) {
        refreshDevices()
        guard autoConnect, phase == .disconnected,
              let address = device.addressString, isPreferred(address),
              let paired = devices.first(where: { $0.address == address }) else { return }
        // Give the audio profiles a moment to come up before opening the control channel.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.phase == .disconnected else { return }
            self.connect(paired)
        }
    }

    private func send(_ payload: [UInt8]) {
        guard let session else { return }
        session.enqueue(payload) { [weak self] error in
            if let error {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Noise control

    func setNoiseMode(_ mode: NoiseControl.Mode) {
        updateNoise { $0.mode = mode }
    }

    func setFocusOnVoice(_ on: Bool) {
        updateNoise { $0.focusOnVoice = on }
    }

    func setAutoAmbient(_ on: Bool) {
        updateNoise { $0.autoAmbient = on }
    }

    func setAutoAmbientSensitivity(_ sensitivity: AutoAmbientSensitivity) {
        updateNoise { $0.autoAmbientSensitivity = sensitivity }
    }

    /// While the slider is dragged the level streams at a limited rate; releasing it sends the final value.
    func setAmbientLevel(_ level: Int, adjusting: Bool) {
        guard var noise = state.noise, let variant = state.noiseVariant else { return }
        noise.ambientLevel = level
        state.noise = noise
        if adjusting {
            guard Date().timeIntervalSince(lastAdjustingSend) > 0.12 else { return }
            lastAdjustingSend = Date()
        }
        send(Request.setNoiseControl(noise, variant: variant, adjusting: adjusting))
    }

    private func updateNoise(_ change: (inout NoiseControl) -> Void) {
        guard var noise = state.noise, let variant = state.noiseVariant else { return }
        change(&noise)
        state.noise = noise
        send(Request.setNoiseControl(noise, variant: variant))
    }

    // MARK: - Equalizer

    func selectPreset(_ id: UInt8) {
        state.equalizer?.presetID = id
        send(Request.selectEqPreset(id))
        // The reply carries the preset's band values.
        send(Request.eqParam)
    }

    func setBand(_ index: Int, to value: Int, commit: Bool) {
        editEqualizer(commit: commit) { eq in
            guard eq.bands.indices.contains(index) else { return }
            eq.bands[index] = value
        }
    }

    func setClearBass(_ value: Int, commit: Bool) {
        editEqualizer(commit: commit) { $0.clearBass = value }
    }

    func resetBands() {
        editEqualizer(commit: true) { eq in
            eq.bands = eq.bands.map { _ in 0 }
            eq.clearBass = 0
        }
    }

    private func editEqualizer(commit: Bool, _ change: (inout Equalizer) -> Void) {
        guard var eq = state.equalizer, eq.layout != nil else { return }
        change(&eq)
        // Moving a band off a built-in preset turns it into the Custom curve, like Sony's app.
        if !eq.isEditablePreset { eq.presetID = Equalizer.customPresetID }
        state.equalizer = eq
        if commit { send(Request.setEqBands(eq)) }
    }

    // MARK: - Other settings

    func setUpscaling(_ on: Bool) {
        state.upscaling = on
        send(Request.setUpscaling(on))
    }

    func setSpeakToChat(_ on: Bool) {
        state.speakToChat = on
        send(Request.setSpeakToChat(on))
    }

    func setSpeakToChatConfig(sensitivity: SpeakToChatSensitivity? = nil, timeout: SpeakToChatTimeout? = nil) {
        let sensitivity = sensitivity ?? state.speakToChatSensitivity ?? .auto
        let timeout = timeout ?? state.speakToChatTimeout ?? .standard
        state.speakToChatSensitivity = sensitivity
        state.speakToChatTimeout = timeout
        send(Request.setSpeakToChatConfig(sensitivity: sensitivity, timeout: timeout))
    }

    func setPauseWhenTakenOff(_ on: Bool) {
        state.pauseWhenTakenOff = on
        send(Request.setPauseWhenTakenOff(on))
    }

    func setAutoPowerOff(_ option: AutoPowerOffOption) {
        guard var value = state.autoPowerOff else { return }
        value.setting = option
        state.autoPowerOff = value
        send(Request.setAutoPowerOff(value))
    }

    func powerOff() {
        send(Request.powerOff)
    }
}
