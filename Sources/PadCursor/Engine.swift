import AppKit
import CoreGraphics
import Foundation
import GameController

/// Reads the controller at 120 Hz and turns it into cursor movement, clicks, scrolling,
/// window moves and key presses, following the user's bindings. Runs on the main thread;
/// Accessibility lookups for the magnet run on a background queue.
final class Engine {
    static let shared = Engine()

    var settings = Settings.defaults
    var onStatus: ((String?) -> Void)?
    var onPause: ((Bool) -> Void)?

    private let tickHz = 120.0
    private var dt: Double { 1 / tickHz }

    // Magnet and flick tuning (the user-facing knobs live in Settings)
    private let frictionTau = 0.05
    private let pullTau = 0.06
    private let pullDelay = 0.08
    private let hoverSlack = 4.0
    private let flickLow: Float = 0.25
    private let flickHigh: Float = 0.55
    private let flickRise = 0.12
    private let flickHoldEscape = 0.35
    private let snapCone = 1.0
    private let glideTau = 0.03
    private let scanRadius = 450.0
    private let scanEvery = 1.5
    private let lookahead = 0.05
    private let probeMinStep = 3.0
    private let cacheTTL = 2.0
    private let swipeThreshold: Float = 0.45
    private let repeatDelay = 0.35
    private let repeatInterval = 0.05

    private var pad: GCExtendedGamepad?
    private var controller: GCController?
    private var timer: Timer?
    private(set) var paused = false
    private let source = CGEventSource(stateID: .hidSystemState)

    // Input state
    private var previous: [String: Bool] = [:]
    private var leftHeld = false, rightHeld = false, middleHeld = false
    private var repeatAction: Action?
    private var repeatControl: Control?
    private var nextRepeat: Date?
    private var lastLeftClick = Date.distantPast
    private var clickCount: Int64 = 1
    private var scrollRemainder = CGPoint.zero
    private var scrollSince: Date?
    private var shoulderUsed: [Control: Bool] = [:]

    // The program's own cursor position. Reading the system cursor back each tick returns a
    // stale value while posted moves are still in flight, which makes the magnet jitter.
    private var pos = CGPoint.zero
    private var lastPosted = CGPoint.zero
    private var idleTicks = 0

    private enum WindowMode { case move, resize }
    private struct WindowGrab { let window: AXUIElement; let mode: WindowMode; var origin: CGPoint; var size: CGSize }
    private var grab: WindowGrab?

    // Magnet state
    private var hover: CGRect?
    private var friction = 1.0
    private var idleSince: Date?
    private var velocity = CGPoint.zero
    private var glideTarget: CGPoint?
    private var flickArmed = true
    private var riseStart: Date?
    private var snapHoldStart: Date?
    private var rawWasLow = true

    private let probeQueue = DispatchQueue(label: "padcursor.ax", qos: .userInteractive)
    private var probeInFlight = false
    private var lastProbePoint = CGPoint(x: -1e6, y: -1e6)
    private var scanInFlight = false
    private var scanCenter = CGPoint(x: -1e6, y: -1e6)
    private var scanTime = Date.distantPast
    private var scanned: [CGRect] = []
    private var probed: [(rect: CGRect, seen: Date)] = []

    private var touchStart: (x: Float, y: Float)?
    private var touchLast: (x: Float, y: Float) = (0, 0)

    // MARK: lifecycle

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            guard let self, (n.object as? GCController) === self.controller else { return }
            self.pad = nil
            self.controller = nil
            self.onStatus?(nil)
        }
        GCController.controllers().first.map(attach)
        pos = systemCursor()
        lastPosted = pos
        timer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func attach(_ c: GCController) {
        guard let g = c.extendedGamepad else { return }
        controller = c
        pad = g
        setLight()
        onStatus?(c.vendorName ?? "Controller")
    }

    func setPaused(_ p: Bool) {
        paused = p
        releaseAll()
        setLight()
        onPause?(p)
    }

    func apply(_ s: Settings) {
        let magnetFlipped = s.magnet != settings.magnet
        settings = s
        if magnetFlipped {
            invalidateButtons()
            glideTarget = nil
        }
        setLight()
    }

    private var lightWasOff = false
    private var lastLightWrite = Date.distantPast

    /// Sets the light bar. After the light was off, the controller can ignore a single color
    /// write, so turning it back on writes a nudge color first and the target again shortly
    /// after; the tick also re-asserts the color every few seconds.
    private func setLight() {
        guard let light = controller?.light else { return }
        lastLightWrite = Date()
        guard settings.lightOn else {
            light.color = GCColor(red: 0, green: 0, blue: 0)
            lightWasOff = true
            return
        }
        let c = paused ? settings.lightPaused : settings.magnet ? settings.lightColor : settings.lightMagnetOff
        let target = GCColor(red: Float(c.r), green: Float(c.g), blue: Float(c.b))
        if lightWasOff {
            lightWasOff = false
            light.color = GCColor(red: 0.02, green: 0.02, blue: 0.02)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.settings.lightOn else { return }
                self.controller?.light?.color = target
            }
        }
        light.color = target
    }

    // MARK: events

    private func systemCursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func clamp(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let b = ids.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        guard !b.isNull else { return p }
        return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
    }

    private func mouse(_ type: CGEventType, _ button: CGMouseButton, at p: CGPoint, clicks: Int64 = 1) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: clicks)
        e?.post(tap: .cghidEventTap)
    }

    private func moveCursor(to p: CGPoint) {
        let c = clamp(p)
        pos = c
        if hypot(c.x - lastPosted.x, c.y - lastPosted.y) < 0.05 { return }
        lastPosted = c
        if leftHeld {
            mouse(.leftMouseDragged, .left, at: c)
        } else if rightHeld {
            mouse(.rightMouseDragged, .right, at: c)
        } else if middleHeld {
            mouse(.otherMouseDragged, .center, at: c)
        } else {
            mouse(.mouseMoved, .left, at: c)
        }
    }

    private func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    private static let modifierOrder: [(CGEventFlags, CGKeyCode)] = [
        (.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55),
    ]

    /// Presses a key with its modifiers held down around it. System shortcuts such as
    /// Ctrl-Arrow for Spaces only fire when the modifier keys themselves are pressed.
    private func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        let mods = Self.modifierOrder.filter { flags.contains($0.0) }
        var held: CGEventFlags = []
        for (f, k) in mods { held.insert(f); postKey(k, down: true, flags: held) }
        var keyFlags = held
        if (123...126).contains(code) { keyFlags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        postKey(code, down: true, flags: keyFlags)
        postKey(code, down: false, flags: keyFlags)
        for (f, k) in mods.reversed() { held.remove(f); postKey(k, down: false, flags: held) }
    }

    /// Holds or releases a key for push-to-talk. Modifier-only keys (fn, ⌃, ⌥, ⇧, ⌘) are sent
    /// as flag changes, the way a keyboard sends them.
    private func holdKey(_ a: Action, down: Bool) {
        let code = CGKeyCode(a.keyCode)
        if let flag = modifierKeyCodes[a.keyCode] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.type = .flagsChanged
            e?.flags = down ? flag : []
            e?.post(tap: .cghidEventTap)
            return
        }
        let flags = CGEventFlags(rawValue: a.flags)
        let mods = Self.modifierOrder.filter { flags.contains($0.0) }
        if down {
            var held: CGEventFlags = []
            for (f, k) in mods { held.insert(f); postKey(k, down: true, flags: held) }
            postKey(code, down: true, flags: held)
        } else {
            postKey(code, down: false, flags: flags)
            var held = flags
            for (f, k) in mods.reversed() { held.remove(f); postKey(k, down: false, flags: held) }
        }
    }

    private func edge(_ name: String, _ pressed: Bool) -> (down: Bool, up: Bool) {
        let was = previous[name] ?? false
        previous[name] = pressed
        return (pressed && !was, !pressed && was)
    }

    // MARK: actions

    /// Runs the press half of an action (or the whole action when it has no hold behavior).
    private func press(_ a: Action, from control: Control?) {
        switch a.kind {
        case .none: break
        case .leftClick:
            let now = Date()
            clickCount = now.timeIntervalSince(lastLeftClick) < NSEvent.doubleClickInterval ? clickCount + 1 : 1
            lastLeftClick = now
            mouse(.leftMouseDown, .left, at: pos, clicks: clickCount)
            leftHeld = true
        case .rightClick:
            mouse(.rightMouseDown, .right, at: pos)
            rightHeld = true
        case .middleClick:
            mouse(.otherMouseDown, .center, at: pos)
            middleHeld = true
        case .delete:
            key(51)
            repeatAction = a
            repeatControl = control
            nextRepeat = Date().addingTimeInterval(repeatDelay)
        case .back: key(33, .maskCommand)
        case .forward: key(30, .maskCommand)
        case .spotlight: key(49, .maskCommand)
        case .missionControl: key(126, .maskControl)
        case .appExpose: key(125, .maskControl)
        case .nextSpace: key(124, .maskControl)
        case .previousSpace: key(123, .maskControl)
        case .arrowUp: key(126)
        case .arrowDown: key(125)
        case .arrowLeft: key(123)
        case .arrowRight: key(124)
        case .shortcut: key(CGKeyCode(a.keyCode), CGEventFlags(rawValue: a.flags))
        case .holdKey: holdKey(a, down: true)
        case .togglePause: DispatchQueue.main.async { Store.shared.paused.toggle() }
        case .toggleMagnet: DispatchQueue.main.async { Store.shared.settings.magnet.toggle() }
        case .quit: NSApp.terminate(nil)
        }
    }

    /// Runs the release half of an action.
    private func release(_ a: Action, from control: Control?) {
        switch a.kind {
        case .leftClick:
            mouse(.leftMouseUp, .left, at: pos, clicks: clickCount)
            leftHeld = false
        case .rightClick:
            mouse(.rightMouseUp, .right, at: pos)
            rightHeld = false
        case .middleClick:
            mouse(.otherMouseUp, .center, at: pos)
            middleHeld = false
        case .delete:
            if repeatControl == control { repeatAction = nil; nextRepeat = nil }
        case .holdKey: holdKey(a, down: false)
        default: break
        }
    }

    private func tap(_ a: Action) {
        press(a, from: nil)
        release(a, from: nil)
    }

    private func releaseAll() {
        if leftHeld { mouse(.leftMouseUp, .left, at: pos); leftHeld = false }
        if rightHeld { mouse(.rightMouseUp, .right, at: pos); rightHeld = false }
        if middleHeld { mouse(.otherMouseUp, .center, at: pos); middleHeld = false }
        repeatAction = nil
        grab = nil
    }

    /// A button bound to an action: press on down, release on up.
    private func handle(_ c: Control, _ pressed: Bool) {
        let e = edge(c.rawValue, pressed)
        let a = settings.action(for: c)
        if e.down { press(a, from: c) }
        if e.up { release(a, from: c) }
    }

    /// L1/R1 with a hold mode: holding plus the stick moves or resizes a window, and the bound
    /// action fires as a tap on release when the stick was not used.
    private func shoulder(_ c: Control, _ pressed: Bool, mode: StickMode) {
        if mode == .none { handle(c, pressed); return }
        let e = edge(c.rawValue, pressed)
        if e.down { shoulderUsed[c] = false }
        if e.up {
            grab = nil
            if shoulderUsed[c] != true { tap(settings.action(for: c)) }
        }
    }

    // MARK: tick

    private func tick() {
        guard let g = pad else { return }
        let now = Date()
        if now.timeIntervalSince(lastLightWrite) > 3 { setLight() }

        if paused {
            // Only the pause binding works while paused.
            for c in Control.allCases where settings.action(for: c).kind == .togglePause {
                if edge(c.rawValue, isPressed(c, g)).down { Store.shared.paused = false }
            }
            return
        }

        let sx = shape(g.leftThumbstick.xAxis.value), sy = -shape(g.leftThumbstick.yAxis.value)
        let stickIdle = sx == 0 && sy == 0
        let l1 = g.leftShoulder.isPressed, r1 = g.rightShoulder.isPressed
        let holdMode: StickMode = l1 ? settings.l1Hold : r1 ? settings.r1Hold : .none

        if holdMode != .none && !stickIdle {
            moveWindow(holdMode == .moveWindow ? .move : .resize, sx, sy)
            shoulderUsed[l1 ? .l1 : .r1] = true
        } else {
            cursorStep(g, now: now)
        }
        shoulder(.l1, l1, mode: settings.l1Hold)
        shoulder(.r1, r1, mode: settings.r1Hold)

        for c in [Control.cross, .circle, .square, .triangle, .l3, .r3, .dpadUp, .dpadDown, .dpadLeft, .dpadRight, .options, .create] {
            handle(c, isPressed(c, g))
        }

        if let a = repeatAction, let r = nextRepeat, now >= r {
            key(51)
            nextRepeat = r.addingTimeInterval(repeatInterval)
            _ = a
        }

        scroll(g, now: now)
        touchpad(g)
    }

    private func isPressed(_ c: Control, _ g: GCExtendedGamepad) -> Bool {
        switch c {
        case .cross: g.buttonA.isPressed
        case .circle: g.buttonB.isPressed
        case .square: g.buttonX.isPressed
        case .triangle: g.buttonY.isPressed
        case .l1: g.leftShoulder.isPressed
        case .r1: g.rightShoulder.isPressed
        case .l3: g.leftThumbstickButton?.isPressed ?? false
        case .r3: g.rightThumbstickButton?.isPressed ?? false
        case .dpadUp: g.dpad.up.isPressed
        case .dpadDown: g.dpad.down.isPressed
        case .dpadLeft: g.dpad.left.isPressed
        case .dpadRight: g.dpad.right.isPressed
        case .touchpadPress: (g as? GCDualSenseGamepad)?.touchpadButton.isPressed ?? false
        case .options: g.buttonMenu.isPressed
        case .create: g.buttonOptions?.isPressed ?? false
        case .swipeLeft, .swipeRight, .swipeUp, .swipeDown: false
        }
    }

    private func shape(_ v: Float) -> Double {
        let a = abs(Double(v))
        let dz = settings.deadzone
        guard a > dz else { return 0 }
        let n = (a - dz) / (1 - dz)
        return (v < 0 ? -1 : 1) * n * n
    }

    private func moveWindow(_ mode: WindowMode, _ sx: Double, _ sy: Double) {
        if grab == nil || grab?.mode != mode {
            if let w = window(at: pos), let f = frame(w) {
                grab = WindowGrab(window: w, mode: mode, origin: f.origin, size: f.size)
            }
        }
        glideTarget = nil
        guard var gr = grab else { return }
        let d = settings.cursorSpeed * 1.15 * dt
        if mode == .move {
            gr.origin.x += sx * d
            gr.origin.y += sy * d
            setAXValue(gr.window, kAXPositionAttribute, .cgPoint, gr.origin)
            moveCursor(to: CGPoint(x: pos.x + sx * d, y: pos.y + sy * d))
        } else {
            gr.size.width = max(240, gr.size.width + sx * d)
            gr.size.height = max(160, gr.size.height + sy * d)
            setAXValue(gr.window, kAXSizeAttribute, .cgSize, gr.size)
        }
        grab = gr
        invalidateButtons()
    }

    /// Right stick scrolling. Holding the stick in one direction speeds scrolling up over
    /// `scrollAccelTime` until it reaches `scrollAccel` times the base speed.
    private func scroll(_ g: GCExtendedGamepad, now: Date) {
        let vy = shape(g.rightThumbstick.yAxis.value), vx = shape(g.rightThumbstick.xAxis.value)
        if vx == 0 && vy == 0 {
            scrollSince = nil
            return
        }
        if scrollSince == nil { scrollSince = now }
        let held = now.timeIntervalSince(scrollSince!)
        let ramp = min(1, held / max(settings.scrollAccelTime, 0.05))
        let accel = 1 + (settings.scrollAccel - 1) * ramp * ramp
        let sign = settings.invertScroll ? -1.0 : 1.0
        let speed = settings.scrollSpeed * accel * dt
        scrollRemainder.y += vy * speed * sign
        scrollRemainder.x -= vx * speed * sign
        let wy = Int32(scrollRemainder.y.rounded(.towardZero)), wx = Int32(scrollRemainder.x.rounded(.towardZero))
        if wx != 0 || wy != 0 {
            scrollRemainder.x -= Double(wx)
            scrollRemainder.y -= Double(wy)
            CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                    wheel1: wy, wheel2: wx, wheel3: 0)?.post(tap: .cghidEventTap)
            invalidateButtons()
        }
    }

    private func touchpad(_ g: GCExtendedGamepad) {
        guard let ds = g as? GCDualSenseGamepad else { return }
        let pressed = ds.touchpadButton.isPressed
        handle(.touchpadPress, pressed)
        if pressed { touchStart = nil; return }   // a press is never a swipe

        let x = ds.touchpadPrimary.xAxis.value, y = ds.touchpadPrimary.yAxis.value
        if x != 0 || y != 0 {
            if touchStart == nil { touchStart = (x, y) }
            touchLast = (x, y)
            return
        }
        guard let s = touchStart else { return }
        touchStart = nil
        let dx = touchLast.x - s.x, dy = touchLast.y - s.y
        guard max(abs(dx), abs(dy)) >= swipeThreshold else { return }
        let c: Control = abs(dx) > abs(dy) ? (dx < 0 ? .swipeLeft : .swipeRight) : (dy > 0 ? .swipeUp : .swipeDown)
        tap(settings.action(for: c))
    }

    // MARK: magnet

    private func invalidateButtons() {
        scanned.removeAll()
        probed.removeAll()
        hover = nil
        scanTime = .distantPast
        lastProbePoint = CGPoint(x: -1e6, y: -1e6)
    }

    private func knownButtons() -> [CGRect] {
        let now = Date()
        probed.removeAll { now.timeIntervalSince($0.seen) > cacheTTL }
        return scanned + probed.map(\.rect)
    }

    private func smallest(containing p: CGPoint, in rects: [CGRect]) -> CGRect? {
        rects.filter { $0.contains(p) }.min { $0.width * $0.height < $1.width * $1.height }
    }

    private func probe(at q: CGPoint) {
        guard !probeInFlight, hypot(q.x - lastProbePoint.x, q.y - lastProbePoint.y) >= probeMinStep else { return }
        probeInFlight = true
        lastProbePoint = q
        probeQueue.async { [weak self] in
            let r = clickableFrame(at: q)
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                guard let r else { return }
                self.probed.removeAll { $0.rect == r }
                self.probed.append((r, Date()))
                if self.probed.count > 64 { self.probed.removeFirst(self.probed.count - 64) }
            }
        }
    }

    private func scan(around c: CGPoint) {
        guard !scanInFlight else { return }
        scanInFlight = true
        scanCenter = c
        let radius = scanRadius
        probeQueue.async { [weak self] in
            let rects = scanButtons(around: c, radius: radius)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                self.scanned = rects
                self.scanTime = Date()
            }
        }
    }

    /// The nearest button in direction `dir` (unit vector) from `p`, inside a cone, preferring
    /// buttons straight ahead over ones that are closer but off to the side.
    private func nextButton(from p: CGPoint, toward dir: CGPoint, excluding current: CGRect?) -> CGRect? {
        var best: (CGRect, Double)?
        for r in knownButtons() {
            if r == current || r.contains(p) { continue }
            let v = CGPoint(x: r.midX - p.x, y: r.midY - p.y)
            let along = v.x * dir.x + v.y * dir.y
            let perp = abs(v.x * dir.y - v.y * dir.x)
            guard along > 4, perp <= along * snapCone, hypot(v.x, v.y) <= settings.snapRange else { continue }
            let score = along + perp * 2.5
            if best == nil || score < best!.1 { best = (r, score) }
        }
        return best?.0
    }

    private func cursorStep(_ g: GCExtendedGamepad, now: Date) {
        let rx = g.leftThumbstick.xAxis.value, ry = g.leftThumbstick.yAxis.value
        let raw = hypot(rx, ry)
        let sx = shape(rx), sy = -shape(ry)
        let stickIdle = sx == 0 && sy == 0
        let magnet = settings.magnet

        // Follow the system cursor only when the controller is idle and something else moved it.
        if stickIdle && glideTarget == nil {
            idleTicks += 1
            if idleTicks > 3 {
                let real = systemCursor()
                if hypot(real.x - lastPosted.x, real.y - lastPosted.y) > 2 {
                    pos = real
                    lastPosted = real
                }
            }
        } else {
            idleTicks = 0
        }

        if magnet {
            let buttons = knownButtons()
            if let h = hover, h.insetBy(dx: -hoverSlack, dy: -hoverSlack).contains(pos) {
                if let inner = smallest(containing: pos, in: buttons), inner != h, h.contains(inner) { hover = inner }
            } else {
                hover = smallest(containing: pos, in: buttons)
            }
            let moving = hypot(velocity.x, velocity.y) > 30
            probe(at: moving ? CGPoint(x: pos.x + velocity.x * lookahead, y: pos.y + velocity.y * lookahead) : pos)
            if hypot(pos.x - scanCenter.x, pos.y - scanCenter.y) > scanRadius * 0.4
                || now.timeIntervalSince(scanTime) > scanEvery {
                scan(around: pos)
            }
        } else {
            hover = nil
        }

        // Flick: the stick leaves rest and reaches flickHigh quickly.
        if raw < flickLow {
            flickArmed = true
            riseStart = nil
            snapHoldStart = nil
        } else if rawWasLow {
            riseStart = now
        }
        rawWasLow = raw < flickLow
        if magnet, settings.flick, flickArmed, raw >= flickHigh, let rs = riseStart,
           now.timeIntervalSince(rs) <= flickRise, hover != nil || glideTarget != nil {
            flickArmed = false
            let dir = CGPoint(x: Double(rx / raw), y: Double(-ry / raw))
            if let next = nextButton(from: glideTarget ?? pos, toward: dir, excluding: hover) {
                glideTarget = CGPoint(x: next.midX, y: next.midY)
                snapHoldStart = now
            }
        }
        if flickArmed && raw >= flickLow && riseStart.map({ now.timeIntervalSince($0) > flickRise }) == true {
            flickArmed = false   // a slow push is normal movement, not a flick
        }

        let snapHolding = snapHoldStart.map { now.timeIntervalSince($0) < flickHoldEscape } ?? false
        var next = pos

        if let t = glideTarget {
            let a = 1 - exp(-dt / glideTau)
            next = CGPoint(x: pos.x + (t.x - pos.x) * a, y: pos.y + (t.y - pos.y) * a)
            if hypot(t.x - next.x, t.y - next.y) < 0.75 {
                next = t
                glideTarget = nil
            }
            velocity = .zero
            idleSince = nil
        } else if !snapHolding {
            var target = 1.0
            if let h = hover {
                let nx = abs(pos.x - h.midX) / max(h.width / 2, 1), ny = abs(pos.y - h.midY) / max(h.height / 2, 1)
                let minFriction = 1 - settings.magnetStrength
                target = minFriction + (1 - minFriction) * min(1, max(nx, ny))
            }
            friction += (target - friction) * (1 - exp(-dt / frictionTau))

            let boost = 1 + (settings.boost - 1) * Double(g.rightTrigger.value)
            let precise = 1 - (1 - settings.precise) * Double(g.leftTrigger.value)
            let speed = settings.cursorSpeed * boost * precise * friction
            let v = CGPoint(x: sx * speed, y: sy * speed)
            let k = 1 - exp(-dt / 0.04)
            velocity.x += (v.x - velocity.x) * k
            velocity.y += (v.y - velocity.y) * k
            next = CGPoint(x: pos.x + v.x * dt, y: pos.y + v.y * dt)

            if stickIdle {
                if idleSince == nil { idleSince = now }
            } else {
                idleSince = nil
            }
            if let h = hover, let s = idleSince, now.timeIntervalSince(s) >= pullDelay, !leftHeld {
                let a = 1 - exp(-dt / pullTau)
                next = CGPoint(x: next.x + (h.midX - next.x) * a, y: next.y + (h.midY - next.y) * a)
            }
        }
        moveCursor(to: next)
    }
}
