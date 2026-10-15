import ApplicationServices
import CoreGraphics
import Foundation

// Accessibility helpers: windows under the cursor and button-like elements for the magnet.
// The scan and probe functions run on a background queue, never on the input loop.

let systemWide: AXUIElement = {
    let s = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(s, 0.03)
    return s
}()

let magnetMaxSize = CGSize(width: 420, height: 160)   // larger elements are containers, not buttons

func element(at p: CGPoint) -> AXUIElement? {
    var el: AXUIElement?
    return AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success ? el : nil
}

func string(_ el: AXUIElement, _ name: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v as? String
}

func elementAttr(_ el: AXUIElement, _ name: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
          CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}

func axValue<T: BitwiseCopyable>(_ el: AXUIElement, _ name: String, _ type: AXValueType, _ empty: T) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success, let v,
          CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = empty
    return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
}

func setAXValue<T: BitwiseCopyable>(_ el: AXUIElement, _ name: String, _ type: AXValueType, _ value: T) {
    var copy = value
    if let v = AXValueCreate(type, &copy) { AXUIElementSetAttributeValue(el, name as CFString, v) }
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let o = axValue(el, kAXPositionAttribute, .cgPoint, CGPoint.zero),
          let s = axValue(el, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
    return CGRect(origin: o, size: s)
}

func hasPress(_ el: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return false }
    return (names as? [String])?.contains(kAXPressAction) ?? false
}

let clickableRoles: Set<String> = [
    "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    "AXMenuItem", "AXMenuBarItem", "AXDisclosureTriangle", "AXComboBox", "AXIncrementor",
    "AXDockItem", "AXTab", "AXSegment",
]
/// Roles that are only clickable when they expose AXPress (web content wraps buttons in these).
let pressCandidateRoles: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXUnknown"]

struct Node {
    var role = ""
    var frame: CGRect?
    var parent: AXUIElement?
    var children: [AXUIElement] = []
}

/// Role, frame, parent and (optionally) children of an element in one Accessibility round trip.
func describe(_ el: AXUIElement, children wantChildren: Bool = false) -> Node {
    var names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute]
    if wantChildren { names.append(kAXChildrenAttribute) }
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
          let v = values as? [CFTypeRef], v.count == names.count else { return Node() }
    func ax(_ x: CFTypeRef) -> AXValue? {
        guard CFGetTypeID(x) == AXValueGetTypeID() else { return nil }
        let a = x as! AXValue
        return AXValueGetType(a) == .axError ? nil : a
    }
    var n = Node()
    n.role = v[0] as? String ?? ""
    var origin = CGPoint.zero, size = CGSize.zero
    if let o = ax(v[1]), let s = ax(v[2]), AXValueGetValue(o, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) {
        n.frame = CGRect(origin: origin, size: size)
    }
    n.parent = CFGetTypeID(v[3]) == AXUIElementGetTypeID() ? (v[3] as! AXUIElement) : nil
    if wantChildren, CFGetTypeID(v[4]) == CFArrayGetTypeID() {
        n.children = (v[4] as! [AnyObject]).compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
        }
    }
    return n
}

func isButtonSized(_ f: CGRect) -> Bool {
    f.width >= 4 && f.height >= 4 && f.width <= magnetMaxSize.width && f.height <= magnetMaxSize.height
}

func isClickable(_ el: AXUIElement, _ n: Node) -> Bool {
    clickableRoles.contains(n.role) || (pressCandidateRoles.contains(n.role) && hasPress(el))
}

/// The frame of the button-like element under `p`, walking up a few parents so that the text
/// or image inside a link or web button still counts.
func clickableFrame(at p: CGPoint) -> CGRect? {
    var el = element(at: p)
    for _ in 0..<3 {
        guard let e = el else { return nil }
        let n = describe(e)
        if n.role == "AXWindow" || n.role == "AXApplication" { return nil }
        if let f = n.frame, f.contains(p), isButtonSized(f), isClickable(e, n) { return f }
        el = n.parent
    }
    return nil
}

func window(at p: CGPoint) -> AXUIElement? {
    guard let el = element(at: p) else { return nil }
    if string(el, kAXRoleAttribute) == "AXWindow" { return el }
    if let w = elementAttr(el, kAXWindowAttribute) { return w }
    var cur: AXUIElement? = el
    for _ in 0..<12 {
        guard let c = cur else { return nil }
        if string(c, kAXRoleAttribute) == "AXWindow" { return c }
        cur = elementAttr(c, kAXParentAttribute)
    }
    return nil
}

/// Every button-like element of the window under `c` within `radius`. Walks the window's
/// Accessibility tree breadth first and skips subtrees whose frame lies outside the region,
/// so large web pages stay cheap.
func scanButtons(around c: CGPoint, radius: Double, maxNodes: Int = 1500) -> [CGRect] {
    guard let win = window(at: c) else { return [] }
    let region = CGRect(x: c.x - radius, y: c.y - radius, width: 2 * radius, height: 2 * radius)
    var queue: [AXUIElement] = [win]
    var head = 0
    var found: [CGRect] = []
    while head < queue.count && head < maxNodes {
        let el = queue[head]
        head += 1
        let n = describe(el, children: true)
        if let f = n.frame, n.role != "AXWindow", !f.isEmpty, !f.intersects(region) { continue }
        if let f = n.frame, f.intersects(region), isButtonSized(f), isClickable(el, n) {
            found.append(f)
            continue   // a button's insides are not separate targets
        }
        queue.append(contentsOf: n.children)
    }
    return found
}
