import SwiftUI
import ServiceManagement

@main
struct XMBridgeApp: App {
    @StateObject private var controller = HeadphoneController()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(controller)
        } label: {
            MenuBarLabel()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var controller: HeadphoneController

    var body: some View {
        if controller.isConnected, let battery = controller.state.battery {
            Label("\(battery.level)%", systemImage: modeSymbol)
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "headphones")
        }
    }

    private var modeSymbol: String {
        switch controller.state.noise?.mode {
        case .ambient: return "ear"
        default: return "headphones"
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("XMBridge: couldn't update login item: \(error)")
        }
    }
}
