import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: Store

    var body: some View {
        TabView {
            ButtonsTab(store: store).tabItem { Label("Buttons", systemImage: "gamecontroller") }
            MovementTab(store: store).tabItem { Label("Movement", systemImage: "cursorarrow.motionlines") }
            LightTab(store: store).tabItem { Label("Light", systemImage: "lightbulb") }
        }
        .padding()
    }
}

// MARK: buttons

struct ButtonsTab: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            Section("Buttons") {
                ForEach(Control.allCases) { c in
                    BindingRow(control: c, action: Binding(
                        get: { store.settings.action(for: c) },
                        set: { store.settings.bindings[c] = $0 }))
                }
            }
            Section("Hold L1 / R1 and move the left stick") {
                Picker("L1 hold", selection: $store.settings.l1Hold) {
                    ForEach(StickMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("R1 hold", selection: $store.settings.r1Hold) {
                    ForEach(StickMode.allCases) { Text($0.title).tag($0) }
                }
                Text("With a hold mode set, L1 and R1 fire their button action on a quick tap.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings to Defaults") { store.settings = .defaults }
            }
        }
        .formStyle(.grouped)
    }
}

struct BindingRow: View {
    let control: Control
    @Binding var action: Action

    var body: some View {
        HStack {
            Picker(control.title, selection: Binding(
                get: { action.kind },
                set: { kind in
                    var a = action
                    a.kind = kind
                    if kind.needsKey && a.keyCode == 0 && a.flags == 0 { a.keyCode = 49 }
                    action = a
                })) {
                ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
            }
            if action.kind.needsKey {
                KeyRecorder(action: $action, allowModifierOnly: action.kind == .holdKey)
                    .frame(width: 130)
            }
        }
    }
}

/// Click, then press a key combination. For push to talk a lone modifier (fn, ⌃, ⌥) also counts.
final class RecorderModel: ObservableObject {
    @Published var recording = false
    var monitor: Any?
}

struct KeyRecorder: View {
    @Binding var action: Action
    let allowModifierOnly: Bool
    @StateObject private var model = RecorderModel()

    var body: some View {
        Button(model.recording ? "Press keys…" : describeKey(action.keyCode, action.flags)) {
            model.recording ? stop() : start()
        }
        .onDisappear { stop() }
    }

    private func start() {
        model.recording = true
        model.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let mods = UInt64(e.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue)
            if e.type == .keyDown {
                if e.keyCode == 53 && mods == 0 { stop(); return nil }   // Esc cancels
                action.keyCode = e.keyCode
                action.flags = mods
                stop()
                return nil
            }
            // flagsChanged: accept a lone modifier for push to talk when it is pressed
            if allowModifierOnly, modifierKeyCodes[e.keyCode] != nil {
                let down = e.keyCode == 63 ? e.modifierFlags.contains(.function) : mods != 0
                if down {
                    action.keyCode = e.keyCode
                    action.flags = 0
                    stop()
                    return nil
                }
            }
            return e
        }
    }

    private func stop() {
        model.recording = false
        if let m = model.monitor { NSEvent.removeMonitor(m) }
        model.monitor = nil
    }
}

// MARK: movement

struct MovementTab: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            Section("Cursor") {
                slider("Speed", $store.settings.cursorSpeed, 400...3000, "%.0f px/s")
                slider("R2 boost", $store.settings.boost, 1...6, "%.1f×")
                slider("L2 precision", $store.settings.precise, 0.1...1, "%.2f×")
                slider("Stick dead zone", $store.settings.deadzone, 0.03...0.3, "%.2f")
            }
            Section("Scroll (right stick)") {
                slider("Speed", $store.settings.scrollSpeed, 200...3000, "%.0f px/s")
                slider("Hold to speed up, up to", $store.settings.scrollAccel, 1...8, "%.1f×")
                slider("Time to full speed", $store.settings.scrollAccelTime, 0.2...4, "%.1f s")
                Toggle("Invert direction", isOn: $store.settings.invertScroll)
            }
            Section("Magnet") {
                Toggle("Sticky buttons", isOn: $store.settings.magnet)
                slider("Stickiness", $store.settings.magnetStrength, 0...0.9, "%.2f")
                    .disabled(!store.settings.magnet)
                Toggle("Flick the stick to jump to the next button", isOn: $store.settings.flick)
                    .disabled(!store.settings.magnet)
                slider("Flick range", $store.settings.snapRange, 100...700, "%.0f px")
                    .disabled(!store.settings.magnet || !store.settings.flick)
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ format: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
        }
    }
}

// MARK: light

struct LightTab: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            Section("Light bar") {
                Toggle("Light on", isOn: $store.settings.lightOn)
                ColorPicker("Normal", selection: color(\.lightColor), supportsOpacity: false)
                ColorPicker("Magnet off", selection: color(\.lightMagnetOff), supportsOpacity: false)
                ColorPicker("Paused", selection: color(\.lightPaused), supportsOpacity: false)
            }
            .disabled(!store.settings.lightOn)
            Text("Works with controllers that have a programmable light, such as the DualSense and DualShock 4.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func color(_ path: WritableKeyPath<Settings, RGB>) -> Binding<Color> {
        Binding(
            get: {
                let c = store.settings[keyPath: path]
                return Color(red: c.r, green: c.g, blue: c.b)
            },
            set: { new in
                let ns = NSColor(new).usingColorSpace(.sRGB) ?? .white
                store.settings[keyPath: path] = RGB(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
            })
    }
}
