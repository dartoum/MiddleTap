import Cocoa
import ApplicationServices
import ServiceManagement
import os

let log = Logger(subsystem: "nl.david.MiddleTap", category: "main")

// MiddleTap: trackpad or Magic Mouse gesture = middle mouse click.
// Uses the private MultitouchSupport framework (same as MiddleClick/BetterTouchTool).

// MARK: - Multitouch (private API via dlopen)

typealias MTDeviceRef = UnsafeMutableRawPointer
typealias MTContactCallback = @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private let mtHandle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
private func mtSym<T>(_ name: String, as _: T.Type) -> T? {
    guard let h = mtHandle, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}
private let MTDeviceCreateList = mtSym("MTDeviceCreateList", as: (@convention(c) () -> Unmanaged<CFArray>).self)
private let MTRegisterContactFrameCallback = mtSym("MTRegisterContactFrameCallback", as: (@convention(c) (MTDeviceRef, MTContactCallback) -> Void).self)
private let MTDeviceStart = mtSym("MTDeviceStart", as: (@convention(c) (MTDeviceRef, Int32) -> Void).self)
private let MTDeviceGetDimensions = mtSym("MTDeviceGetSensorSurfaceDimensions", as: (@convention(c) (MTDeviceRef, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void).self)

// MTTouch is 96 bytes; normalized x/y (0...1) live at offsets 32 and 36.
private let touchStride = 96

// MARK: - Settings

enum TrackpadMode: Int, CaseIterable {
    case off, click3, click4, tap3, tap4
    var title: String { ["None", "Three Finger Click", "Four Finger Click", "Three Finger Tap", "Four Finger Tap"][rawValue] }
    var fingers: Int { [0, 3, 4, 3, 4][rawValue] }
    var isTap: Bool { self == .tap3 || self == .tap4 }
}

enum MouseMode: Int, CaseIterable {
    case off, centerClick, click2, click3, tap3
    var title: String { ["None", "Click in Center", "Two Finger Click", "Three Finger Click", "Three Finger Tap"][rawValue] }
    var fingers: Int { [0, 1, 2, 3, 3][rawValue] }
    var isTap: Bool { self == .tap3 }
}

enum Prefs {
    static let d = UserDefaults.standard
    static var trackpad: TrackpadMode {
        get { TrackpadMode(rawValue: d.object(forKey: "trackpad") as? Int ?? TrackpadMode.off.rawValue) ?? .off }
        set { d.set(newValue.rawValue, forKey: "trackpad") }
    }
    static var mouse: MouseMode {
        get { MouseMode(rawValue: d.object(forKey: "mouse") as? Int ?? MouseMode.centerClick.rawValue) ?? .off }
        set { d.set(newValue.rawValue, forKey: "mouse") }
    }
    static var fnClick: Bool { get { d.bool(forKey: "fnClick") } set { d.set(newValue, forKey: "fnClick") } }
    static var onlyInApps: Bool { get { d.bool(forKey: "onlyInApps") } set { d.set(newValue, forKey: "onlyInApps") } }
    // [bundleID: display name]
    static var apps: [String: String] { get { d.dictionary(forKey: "apps") as? [String: String] ?? [:] } set { d.set(newValue, forKey: "apps") } }
}

enum Config {
    static let maxTapDuration = 0.35
    static let maxMovement: Float = 0.06   // normalized distance
}

// MARK: - Device state

final class Dev {
    var isMouse = false
    var fingers = 0
    var maxFingers = 0
    var startTime = 0.0
    var startPos: (x: Float, y: Float) = (0, 0)
    var lastPos: (x: Float, y: Float) = (0, 0)
    var consumedByClick = false
    // Magic Mouse: number of fingers not resting on the edge.
    var innerFingers = 0
    var leftX: Float = 0     // leftmost touch = index finger
    var allX: [Float] = []   // all touch x-positions (debug log)
}

enum MouseZone {
    // Measured with an index+middle finger grip: index finger x≈0.40 (left click),
    // middle finger x≈0.86, index finger slid to the center x≈0.52 (middle click).
    static let edge: ClosedRange<Float> = 0.2...0.8
    static let center: ClosedRange<Float> = 0.43...0.62
}

let lock = NSLock()
var devices: [UnsafeMutableRawPointer: Dev] = [:]
var activeDev: Dev?          // device touched most recently
var middleDown = false       // click currently being converted

func postMiddle(_ type: CGEventType, at point: CGPoint) {
    guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center) else { return }
    e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    e.post(tap: .cghidEventTap)
}

// Is the frontmost app on the list? (Only relevant when "Only in selected apps" is on.)
func appAllowed() -> Bool {
    guard Prefs.onlyInApps else { return true }
    guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    return Prefs.apps[id] != nil
}

func middleClick() {
    guard appAllowed() else { return }
    let p = CGEvent(source: nil)?.location ?? .zero
    postMiddle(.otherMouseDown, at: p)
    postMiddle(.otherMouseUp, at: p)
}

let contactCallback: MTContactCallback = { ref, data, count, timestamp, _ in
    guard let ref else { return 0 }
    lock.lock(); defer { lock.unlock() }
    guard let s = devices[ref] else { return 0 }
    let n = Int(count)

    if n > 0, let data {
        var sx: Float = 0, sy: Float = 0
        s.innerFingers = 0
        s.leftX = 1
        s.allX = []
        for i in 0..<n {
            let base = data.advanced(by: i * touchStride)
            let x = base.load(fromByteOffset: 32, as: Float.self)
            sx += x
            s.leftX = min(s.leftX, x)
            s.allX.append(x)
            sy += base.load(fromByteOffset: 36, as: Float.self)
            if MouseZone.edge.contains(x) { s.innerFingers += 1 }
        }
        let c = (x: sx / Float(n), y: sy / Float(n))
        if s.fingers == 0 { s.startPos = c; s.startTime = timestamp; s.maxFingers = 0; s.consumedByClick = false }
        s.lastPos = c
        activeDev = s
    }
    s.maxFingers = max(s.maxFingers, n)
    s.fingers = n

    if n == 0 {
        let wanted = s.isMouse ? Prefs.mouse : nil
        let tapFingers: Int? = s.isMouse
            ? (wanted!.isTap ? wanted!.fingers : nil)
            : (Prefs.trackpad.isTap ? Prefs.trackpad.fingers : nil)
        if let t = tapFingers, s.maxFingers == t,
           timestamp - s.startTime < Config.maxTapDuration,
           abs(s.lastPos.x - s.startPos.x) < Config.maxMovement,
           abs(s.lastPos.y - s.startPos.y) < Config.maxMovement,
           !s.consumedByClick {
            DispatchQueue.main.async { middleClick() }
        }
        s.maxFingers = 0
    }
    return 0
}

// Keep old lists alive so device pointers are never reused.
var deviceLists: [CFArray] = []

// Called periodically and after wake: a Bluetooth Magic Mouse gets a new device after sleep or
// reconnecting. Scanning only once at launch missed that.
func scanMultitouch(restartAll: Bool = false) {
    guard let list = MTDeviceCreateList?().takeRetainedValue(),
          let register = MTRegisterContactFrameCallback, let start = MTDeviceStart else {
        NSLog("MultitouchSupport unavailable")
        return
    }
    deviceLists.append(list)
    for i in 0..<CFArrayGetCount(list) {
        let dev = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: MTDeviceRef.self)
        lock.lock(); let known = devices[dev] != nil; lock.unlock()
        if known {
            if restartAll { start(dev, 0) }
            continue
        }
        let s = Dev()
        var w: Int32 = 0, h: Int32 = 0
        MTDeviceGetDimensions?(dev, &w, &h)
        s.isMouse = h > w   // Magic Mouse is portrait, trackpads are landscape
        log.notice("new device \(i): \(w)x\(h) mouse=\(s.isMouse)")
        lock.lock(); devices[dev] = s; lock.unlock()
        register(dev, contactCallback)
        start(dev, 0)
    }
    if deviceLists.count > 20 { deviceLists.removeFirst(deviceLists.count - 20) }
}

func startMultitouch() {
    scanMultitouch()
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in scanMultitouch() }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        log.notice("wake: restarting devices")
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        scanMultitouch(restartAll: true)
    }
}

// MARK: - Convert physical click to middle click

func shouldConvertClick(flags: CGEventFlags) -> Bool {
    guard appAllowed() else { return false }
    if Prefs.fnClick && flags.contains(.maskSecondaryFn) { return true }
    lock.lock(); defer { lock.unlock() }
    if let d = activeDev {
        log.notice("click: mouse=\(d.isMouse) fingers=\(d.fingers) inner=\(d.innerFingers) index=\(d.leftX) mode=\(Prefs.mouse.rawValue)")
    } else {
        log.notice("click: no active device")
    }
    guard let d = activeDev, d.fingers > 0 else { return false }
    if d.isMouse {
        let m = Prefs.mouse
        if m == .centerClick {
            let hit = MouseZone.center.contains(d.leftX)
            log.notice("click: all=\(d.allX.map { String(format: "%.2f", $0) }) index=\(String(format: "%.3f", d.leftX)) -> \(hit ? "MIDDLE" : "left")")
            return hit
        }
        guard m != .off, !m.isTap, d.innerFingers == m.fingers else { return false }
        d.consumedByClick = true
        return true
    }
    let m = Prefs.trackpad
    guard m != .off, !m.isTap, d.fingers == m.fingers else { return false }
    d.consumedByClick = true
    return true
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    // Rewrite the event itself instead of posting a new one, so modifiers (Shift = orbit
    // in Fusion) and movement deltas carry over.
    case .leftMouseDown where shouldConvertClick(flags: event.flags):
        middleDown = true
        return asMiddle(event, .otherMouseDown)
    case .leftMouseDragged where middleDown:
        return asMiddle(event, .otherMouseDragged)
    case .leftMouseUp where middleDown:
        middleDown = false
        return asMiddle(event, .otherMouseUp)
    default:
        return Unmanaged.passUnretained(event)
    }
}

func asMiddle(_ event: CGEvent, _ type: CGEventType) -> Unmanaged<CGEvent> {
    event.type = type
    event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
    return Unmanaged.passUnretained(event)
}

var eventTap: CFMachPort?
func installClickTap() {
    guard eventTap == nil else { return }
    let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        .reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else {
        NSLog("Event tap failed: no Accessibility permission")
        return
    }
    eventTap = tap
    log.notice("event tap installed")
    let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

// MARK: - Menu bar

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "magicmouse", accessibilityDescription: "MiddleTap")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log.notice("start, accessibility=\(trusted)")
        if trusted { installClickTap() } else { pollForTrust() }
        startMultitouch()
    }

    func pollForTrust() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if AXIsProcessTrusted() { t.invalidate(); installClickTap() }
        }
    }

    // Rebuild the menu on every open so checkmarks are correct.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let tp = NSMenu(), mm = NSMenu()
        for m in TrackpadMode.allCases {
            let i = NSMenuItem(title: m.title, action: #selector(pickTrackpad(_:)), keyEquivalent: "")
            i.tag = m.rawValue; i.target = self; i.state = Prefs.trackpad == m ? .on : .off; tp.addItem(i)
        }
        for m in MouseMode.allCases {
            let i = NSMenuItem(title: m.title, action: #selector(pickMouse(_:)), keyEquivalent: "")
            i.tag = m.rawValue; i.target = self; i.state = Prefs.mouse == m ? .on : .off; mm.addItem(i)
        }
        mm.addItem(.separator())
        add(mm, "Fn + Click", #selector(toggleFn), Prefs.fnClick)
        let a = NSMenuItem(title: "Trackpad", action: nil, keyEquivalent: ""); a.submenu = tp; menu.addItem(a)
        let b = NSMenuItem(title: "Magic Mouse", action: nil, keyEquivalent: ""); b.submenu = mm; menu.addItem(b)
        menu.addItem(.separator())
        let appsItem = NSMenuItem(title: Prefs.onlyInApps ? "Apps (\(Prefs.apps.count) selected)" : "Apps (active everywhere)", action: nil, keyEquivalent: "")
        appsItem.submenu = buildAppsMenu(); menu.addItem(appsItem)
        menu.addItem(.separator())
        add(menu, "Launch on login", #selector(toggleLogin), SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MiddleTap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func buildAppsMenu() -> NSMenu {
        let m = NSMenu()
        add(m, "Only in selected apps", #selector(toggleOnlyInApps), Prefs.onlyInApps)
        m.addItem(.separator())
        for (id, name) in Prefs.apps.sorted(by: { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }) {
            let i = NSMenuItem(title: name, action: #selector(removeApp(_:)), keyEquivalent: "")
            i.representedObject = id; i.target = self; i.state = .on; m.addItem(i)
        }
        if Prefs.apps.isEmpty {
            let hint = NSMenuItem(title: "No apps selected yet", action: nil, keyEquivalent: ""); hint.isEnabled = false; m.addItem(hint)
        } else {
            let hint = NSMenuItem(title: "Click an app to remove it", action: nil, keyEquivalent: ""); hint.isEnabled = false; m.addItem(hint)
        }
        m.addItem(.separator())
        if let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier,
           id != Bundle.main.bundleIdentifier, Prefs.apps[id] == nil {
            let i = NSMenuItem(title: "Add \(front.localizedName ?? id)", action: #selector(addFrontApp(_:)), keyEquivalent: "")
            i.representedObject = [id, front.localizedName ?? id]; i.target = self; m.addItem(i)
        }
        let pick = NSMenuItem(title: "Choose App…", action: #selector(pickApp), keyEquivalent: "")
        pick.target = self; m.addItem(pick)
        return m
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ on: Bool) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self; i.state = on ? .on : .off; menu.addItem(i)
    }

    @objc func pickTrackpad(_ s: NSMenuItem) { Prefs.trackpad = TrackpadMode(rawValue: s.tag) ?? .off }
    @objc func pickMouse(_ s: NSMenuItem) { Prefs.mouse = MouseMode(rawValue: s.tag) ?? .off }
    @objc func toggleOnlyInApps() { Prefs.onlyInApps.toggle() }
    @objc func removeApp(_ s: NSMenuItem) { if let id = s.representedObject as? String { Prefs.apps[id] = nil } }
    @objc func addFrontApp(_ s: NSMenuItem) {
        if let a = s.representedObject as? [String], a.count == 2 { Prefs.apps[a[0]] = a[1]; Prefs.onlyInApps = true }
    }
    @objc func pickApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier else { continue }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            Prefs.apps[id] = name
        }
        if !Prefs.apps.isEmpty { Prefs.onlyInApps = true }
    }
    @objc func toggleFn() { Prefs.fnClick.toggle() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("Login item failed: \(error)") }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
