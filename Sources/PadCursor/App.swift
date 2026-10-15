import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@main
struct PadCursorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Image(systemName: store.paused ? "gamecontroller" : "gamecontroller.fill")
        }
        Window("PadCursor Settings", id: "settings") {
            SettingsView(store: store)
                .frame(minWidth: 560, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = Store.shared
        let engine = Engine.shared
        engine.onStatus = { name in DispatchQueue.main.async { store.controllerName = name } }
        engine.apply(store.settings)
        store.launchAtLogin = SMAppService.mainApp.status == .enabled
        engine.start()
        store.trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        // Re-check the permission until it is granted, so the menu updates without a restart.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            let ok = AXIsProcessTrusted()
            if ok != store.trusted { store.trusted = ok }
            if ok { t.invalidate() }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(store.controllerName.map { "Connected: \($0)" } ?? "No controller connected")
        if !store.trusted {
            Button("Grant Accessibility Permission…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        Divider()
        Toggle("Paused", isOn: $store.paused)
        Toggle("Magnet (sticky buttons)", isOn: $store.settings.magnet)
        Toggle("Flick to next button", isOn: $store.settings.flick)
            .disabled(!store.settings.magnet)
        Toggle("Light bar", isOn: $store.settings.lightOn)
        Divider()
        Toggle("Launch at Login", isOn: Binding(
            get: { store.launchAtLogin },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("PadCursor: launch at login failed: \(error)")
                }
                store.launchAtLogin = SMAppService.mainApp.status == .enabled
            }))
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit PadCursor") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
