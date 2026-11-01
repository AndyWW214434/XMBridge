import AppKit
import MDRKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: HeadphoneController

    var body: some View {
        VStack(spacing: 10) {
            if controller.isConnected {
                ConnectedView()
            } else {
                DisconnectedView()
            }
        }
        .padding(12)
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !controller.isConnected { controller.refreshDevices() }
        }
    }
}

// MARK: - Connected

private struct ConnectedView: View {
    @EnvironmentObject private var controller: HeadphoneController

    var body: some View {
        let state = controller.state
        HeaderView()
        if state.noiseVariant != nil, let noise = state.noise {
            NoiseControlCard(noise: noise, hasAutoAmbient: state.noiseVariant == .noiseAdaptation)
        }
        if state.supportsEqualizer, let equalizer = state.equalizer {
            EqualizerCard(equalizer: equalizer, presets: state.availablePresets, isAvailable: state.eqAvailable)
        }
        FeaturesCard()
        if let message = controller.errorMessage {
            ErrorText(message: message)
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var controller: HeadphoneController
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        let state = controller.state
        HStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 22, weight: .regular))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.07), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let battery = state.battery {
                        Label("\(battery.level)%", systemImage: batterySymbol(battery))
                            .foregroundStyle(battery.level <= 15 && !battery.isCharging ? Color.red : Color.secondary)
                    }
                    if let codec = state.codec, codec != .unsettled {
                        Text(codec.name)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                if let firmware = state.firmwareVersion {
                    Text("Firmware \(firmware)")
                    Divider()
                }
                Button("Disconnect") { controller.disconnect() }
                if state.supports(.powerOff) {
                    Button("Turn Off Headphones") { controller.powerOff() }
                }
                Divider()
                Toggle("Connect Automatically", isOn: $controller.autoConnect)
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { LoginItem.setEnabled($0) }
                Divider()
                Button("Quit XMBridge") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func batterySymbol(_ battery: Battery) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.level {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }
}

private struct NoiseControlCard: View {
    @EnvironmentObject private var controller: HeadphoneController
    let noise: NoiseControl
    let hasAutoAmbient: Bool

    var body: some View {
        Card("Noise Control") {
            HStack(spacing: 8) {
                ModeTile(title: "Noise Canceling", symbol: "waveform.slash", isSelected: noise.mode == .noiseCanceling) {
                    controller.setNoiseMode(.noiseCanceling)
                }
                ModeTile(title: "Ambient", symbol: "ear.and.waveform", isSelected: noise.mode == .ambient) {
                    controller.setNoiseMode(.ambient)
                }
                ModeTile(title: "Off", symbol: "power", isSelected: noise.mode == .off) {
                    controller.setNoiseMode(.off)
                }
            }

            if noise.mode == .ambient {
                VStack(alignment: .leading, spacing: 8) {
                    if !(hasAutoAmbient && noise.autoAmbient) {
                        HStack(spacing: 8) {
                            Text("Level")
                                .font(.callout)
                            StepSlider(value: noise.ambientLevel, range: NoiseControl.ambientLevels) { level, commit in
                                controller.setAmbientLevel(level, adjusting: !commit)
                            }
                            Text("\(noise.ambientLevel)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                        }
                    }
                    if hasAutoAmbient {
                        ToggleRow(
                            title: "Auto Ambient Sound",
                            subtitle: "Adjusts the level to your surroundings",
                            isOn: noise.autoAmbient,
                            set: controller.setAutoAmbient
                        )
                        if noise.autoAmbient {
                            PickerRow(
                                title: "Sensitivity",
                                selection: noise.autoAmbientSensitivity,
                                options: AutoAmbientSensitivity.allCases,
                                name: \.name,
                                set: controller.setAutoAmbientSensitivity
                            )
                            .controlSize(.small)
                        }
                    }
                    ToggleRow(title: "Focus on Voice", isOn: noise.focusOnVoice, set: controller.setFocusOnVoice)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct EqualizerCard: View {
    @EnvironmentObject private var controller: HeadphoneController
    let equalizer: Equalizer
    let presets: [EqPreset]
    let isAvailable: Bool

    var body: some View {
        Card("Equalizer", trailing: AnyView(presetPicker)) {
            if let layout = equalizer.layout {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(layout.bandLabels.enumerated()), id: \.offset) { index, label in
                        BandSlider(
                            label: label,
                            value: equalizer.bands.indices.contains(index) ? equalizer.bands[index] : 0,
                            range: layout.range
                        ) { value, commit in
                            controller.setBand(index, to: value, commit: commit)
                        }
                    }
                }
                if layout.hasClearBass {
                    HStack(spacing: 8) {
                        Text("Clear Bass")
                            .font(.callout)
                        StepSlider(value: equalizer.clearBass, range: layout.range) { value, commit in
                            controller.setClearBass(value, commit: commit)
                        }
                        Text(equalizer.clearBass > 0 ? "+\(equalizer.clearBass)" : "\(equalizer.clearBass)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .trailing)
                    }
                }
                HStack {
                    Text(layout == .tenBands ? "Hz · ±6 steps" : "Hz · ±10 steps")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Flat") { controller.resetBands() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if !isAvailable {
                Text("The equalizer isn't available in the current listening mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.6)
    }

    private var presetPicker: some View {
        Picker("Preset", selection: Binding(get: { equalizer.presetID }, set: controller.selectPreset)) {
            ForEach(pickerPresets) { Text($0.name).tag($0.id) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    /// The listed presets, plus the current one if the device is on something it didn't list.
    private var pickerPresets: [EqPreset] {
        presets.contains(where: { $0.id == equalizer.presetID }) ? presets : presets + [EqPreset(id: equalizer.presetID)]
    }
}

private struct FeaturesCard: View {
    @EnvironmentObject private var controller: HeadphoneController

    var body: some View {
        let state = controller.state
        let hasAny = state.upscaling != nil || state.speakToChat != nil
            || state.pauseWhenTakenOff != nil || state.autoPowerOff != nil
        if hasAny {
            Card("Settings") {
                if let upscaling = state.upscaling {
                    ToggleRow(title: "DSEE Extreme", subtitle: "Upscales compressed audio", isOn: upscaling, set: controller.setUpscaling)
                }
                if let speakToChat = state.speakToChat {
                    ToggleRow(title: "Speak-to-Chat", subtitle: "Pauses music when you talk", isOn: speakToChat, set: controller.setSpeakToChat)
                    if speakToChat, state.speakToChatSensitivity != nil || state.speakToChatTimeout != nil {
                        PickerRow(
                            title: "Voice detection",
                            selection: state.speakToChatSensitivity ?? .auto,
                            options: SpeakToChatSensitivity.allCases,
                            name: \.name,
                            set: { controller.setSpeakToChatConfig(sensitivity: $0) }
                        )
                        PickerRow(
                            title: "End after",
                            selection: state.speakToChatTimeout ?? .standard,
                            options: SpeakToChatTimeout.allCases,
                            name: \.name,
                            set: { controller.setSpeakToChatConfig(timeout: $0) }
                        )
                    }
                }
                if let pause = state.pauseWhenTakenOff {
                    ToggleRow(title: "Pause When Taken Off", isOn: pause, set: controller.setPauseWhenTakenOff)
                }
                if let autoPowerOff = state.autoPowerOff {
                    PickerRow(
                        title: "Auto power off",
                        selection: autoPowerOff.setting,
                        options: autoPowerOff.options,
                        name: \.name,
                        set: controller.setAutoPowerOff
                    )
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Disconnected

private struct DisconnectedView: View {
    @EnvironmentObject private var controller: HeadphoneController

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "headphones")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Text(title)
                .font(.headline)
            Text("Connect your WH-1000XM5 or WH-1000XM6 in Bluetooth settings first, then pick it below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)

        Card("Paired Headphones", trailing: AnyView(refreshButton)) {
            if controller.devices.isEmpty {
                Text("No Sony WH-1000XM5/XM6 headphones are paired with this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.devices) { device in
                    DeviceRow(device: device)
                }
            }
        }

        if let message = controller.errorMessage {
            ErrorText(message: message)
        }

        HStack {
            Toggle("Connect automatically", isOn: $controller.autoConnect)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Bluetooth Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 4)
    }

    private var title: String {
        if case .connecting(let name) = controller.phase { return "Connecting to \(name)…" }
        return "Not Connected"
    }

    private var refreshButton: some View {
        Button {
            controller.refreshDevices()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help("Refresh")
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var controller: HeadphoneController
    let device: PairedHeadphones

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(device.isConnected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                Text(device.isConnected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if case .connecting = controller.phase {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Connect") { controller.connect(device) }
                    .controlSize(.small)
            }
        }
    }
}

private struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}
