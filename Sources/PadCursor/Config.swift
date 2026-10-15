import CoreGraphics
import Foundation

/// A physical input on the controller that can be bound to an action.
enum Control: String, CaseIterable, Codable, Identifiable {
    case cross, circle, square, triangle
    case l1, r1, l3, r3
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case touchpadPress, swipeLeft, swipeRight, swipeUp, swipeDown
    case r3Up, r3Down
    case options, create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cross: "✕ Cross"
        case .circle: "○ Circle"
        case .square: "□ Square"
        case .triangle: "△ Triangle"
        case .l1: "L1 (tap)"
        case .r1: "R1 (tap)"
        case .l3: "L3 (press left stick)"
        case .r3: "R3 (tap the right stick in)"
        case .dpadUp: "D-pad up"
        case .dpadDown: "D-pad down"
        case .dpadLeft: "D-pad left"
        case .dpadRight: "D-pad right"
        case .touchpadPress: "Touchpad press"
        case .swipeLeft: "Touchpad swipe left"
        case .swipeRight: "Touchpad swipe right"
        case .swipeUp: "Touchpad swipe up"
        case .swipeDown: "Touchpad swipe down"
        case .r3Up: "R3 hold + push up"
        case .r3Down: "R3 hold + push down"
        case .options: "Options"
        case .create: "Create"
        }
    }
}

enum ActionKind: String, CaseIterable, Codable, Identifiable {
    case none
    case leftClick, rightClick, middleClick
    case delete
    case back, forward, spotlight
    case missionControl, appExpose, nextSpace, previousSpace
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case scrollToTop, scrollToBottom
    case appSwitcher
    case shortcut, holdKey
    case togglePause, toggleMagnet, quit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Nothing"
        case .leftClick: "Left click / drag"
        case .rightClick: "Right click"
        case .middleClick: "Middle click"
        case .delete: "Delete (repeats while held)"
        case .back: "Back (⌘[)"
        case .forward: "Forward (⌘])"
        case .spotlight: "Spotlight (⌘Space)"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .nextSpace: "Next Space"
        case .previousSpace: "Previous Space"
        case .arrowUp: "Arrow up"
        case .arrowDown: "Arrow down"
        case .arrowLeft: "Arrow left"
        case .arrowRight: "Arrow right"
        case .scrollToTop: "Scroll to the top"
        case .scrollToBottom: "Scroll to the bottom"
        case .appSwitcher: "App switcher (hold, tap R1 / L1 to step)"
        case .shortcut: "Keyboard shortcut…"
        case .holdKey: "Hold a key (push to talk)…"
        case .togglePause: "Pause / resume"
        case .toggleMagnet: "Magnet on / off"
        case .quit: "Quit PadCursor"
        }
    }

    var needsKey: Bool { self == .shortcut || self == .holdKey }
}

struct Action: Codable, Equatable {
    var kind: ActionKind
    var keyCode: UInt16 = 0
    var flags: UInt64 = 0   // CGEventFlags raw value (same bits as NSEvent.ModifierFlags)

    static let none = Action(kind: .none)
    static func of(_ kind: ActionKind) -> Action { Action(kind: kind) }
}

/// What holding a shoulder button turns the left stick into.
enum StickMode: String, CaseIterable, Codable, Identifiable {
    case none, moveWindow, resizeWindow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Nothing"
        case .moveWindow: "Move the window under the cursor"
        case .resizeWindow: "Resize the window under the cursor"
        }
    }
}

/// A light bar color, stored as plain RGB so it survives JSON.
struct RGB: Codable, Equatable {
    var r: Double, g: Double, b: Double
}

struct Settings: Codable, Equatable {
    var bindings: [Control: Action]
    var l1Hold: StickMode = .moveWindow
    var r1Hold: StickMode = .resizeWindow

    var cursorSpeed = 1400.0
    var boost = 3.0
    var precise = 0.25
    var scrollSpeed = 900.0
    var invertScroll = false
    var scrollAccel = 4.0         // scroll speed multiplier reached by holding the right stick
    var scrollAccelTime = 1.2     // s of continuous scrolling to reach it
    var deadzone = 0.10

    var magnet = true
    var magnetStrength = 0.6      // 0 = no slowdown on buttons, 0.9 = very sticky
    var flick = true
    var snapRange = 320.0

    var lightOn = true
    var lightColor = RGB(r: 0, g: 0.4, b: 1)          // normal
    var lightMagnetOff = RGB(r: 0.6, g: 0, b: 1)      // magnet turned off
    var lightPaused = RGB(r: 1, g: 0, b: 0)           // paused

    static let defaults = Settings(bindings: [
        .cross: .of(.leftClick),
        .circle: .of(.rightClick),
        .square: .of(.delete),
        .triangle: .of(.appSwitcher),
        .l1: .of(.back),
        .r1: .of(.forward),
        .l3: .of(.middleClick),
        .r3: .of(.spotlight),
        .dpadUp: .of(.arrowUp),
        .dpadDown: .of(.arrowDown),
        .dpadLeft: .of(.arrowLeft),
        .dpadRight: .of(.arrowRight),
        .touchpadPress: Action(kind: .holdKey, keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue),
        .swipeLeft: .of(.nextSpace),
        .swipeRight: .of(.previousSpace),
        .swipeUp: .of(.missionControl),
        .swipeDown: .of(.appExpose),
        .r3Up: .of(.scrollToTop),
        .r3Down: .of(.scrollToBottom),
        .options: .of(.toggleMagnet),
        .create: .of(.quit),
    ])

    func action(for c: Control) -> Action { bindings[c] ?? .none }

    init(bindings: [Control: Action]) { self.bindings = bindings }

    // Missing keys fall back to defaults, so settings saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings(bindings: [:])
        bindings = try c.decodeIfPresent([Control: Action].self, forKey: .bindings) ?? [:]
        l1Hold = try c.decodeIfPresent(StickMode.self, forKey: .l1Hold) ?? d.l1Hold
        r1Hold = try c.decodeIfPresent(StickMode.self, forKey: .r1Hold) ?? d.r1Hold
        cursorSpeed = try c.decodeIfPresent(Double.self, forKey: .cursorSpeed) ?? d.cursorSpeed
        boost = try c.decodeIfPresent(Double.self, forKey: .boost) ?? d.boost
        precise = try c.decodeIfPresent(Double.self, forKey: .precise) ?? d.precise
        scrollSpeed = try c.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? d.scrollSpeed
        invertScroll = try c.decodeIfPresent(Bool.self, forKey: .invertScroll) ?? d.invertScroll
        scrollAccel = try c.decodeIfPresent(Double.self, forKey: .scrollAccel) ?? d.scrollAccel
        scrollAccelTime = try c.decodeIfPresent(Double.self, forKey: .scrollAccelTime) ?? d.scrollAccelTime
        deadzone = try c.decodeIfPresent(Double.self, forKey: .deadzone) ?? d.deadzone
        magnet = try c.decodeIfPresent(Bool.self, forKey: .magnet) ?? d.magnet
        magnetStrength = try c.decodeIfPresent(Double.self, forKey: .magnetStrength) ?? d.magnetStrength
        flick = try c.decodeIfPresent(Bool.self, forKey: .flick) ?? d.flick
        snapRange = try c.decodeIfPresent(Double.self, forKey: .snapRange) ?? d.snapRange
        lightOn = try c.decodeIfPresent(Bool.self, forKey: .lightOn) ?? d.lightOn
        lightColor = try c.decodeIfPresent(RGB.self, forKey: .lightColor) ?? d.lightColor
        lightMagnetOff = try c.decodeIfPresent(RGB.self, forKey: .lightMagnetOff) ?? d.lightMagnetOff
        lightPaused = try c.decodeIfPresent(RGB.self, forKey: .lightPaused) ?? d.lightPaused
    }
}

/// Holds the settings, saves them, and hands every change to the engine.
final class Store: ObservableObject {
    static let shared = Store()
    private let key = "settings.v1"

    @Published var settings: Settings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
            Engine.shared.apply(settings)
        }
    }
    @Published var controllerName: String?
    @Published var paused = false {
        didSet { Engine.shared.setPaused(paused) }
    }
    @Published var trusted = false
    @Published var launchAtLogin = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            var merged = s
            for c in Control.allCases where merged.bindings[c] == nil {
                merged.bindings[c] = Settings.defaults.bindings[c]
            }
            // 1.3: Triangle moved from Pause (now only in the menu) to the app switcher.
            if !UserDefaults.standard.bool(forKey: "migrated.1.3") {
                if merged.bindings[.triangle]?.kind == .togglePause { merged.bindings[.triangle] = .of(.appSwitcher) }
                UserDefaults.standard.set(true, forKey: "migrated.1.3")
            }
            settings = merged
        } else {
            settings = .defaults
        }
    }
}

// MARK: key names for display

let modifierKeyCodes: [UInt16: CGEventFlags] = [
    54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift,
    58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
]

private let keyNames: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
    13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
    35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
    45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
    54: "Right ⌘", 55: "⌘", 56: "⇧", 58: "⌥", 59: "⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "fn",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12",
    118: "F4", 120: "F2", 122: "F1", 117: "Forward Delete", 115: "Home", 119: "End", 116: "Page Up",
    121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
]

func describeKey(_ code: UInt16, _ flags: UInt64) -> String {
    let f = CGEventFlags(rawValue: flags)
    var s = ""
    if modifierKeyCodes[code] == nil {
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
    }
    return s + (keyNames[code] ?? "Key \(code)")
}
