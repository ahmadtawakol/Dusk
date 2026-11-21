// Dusk: a menu bar screen filter for working at night.
// Scroll over the menu bar icon to change the intensity; click it for a menu.

import AppKit
import ServiceManagement
import Sparkle

// MARK: - Tuning

/// The colour at 100% intensity along the Max Warmth slider, as green and blue levels (red always stays at full):
/// a little warmer, amber, orange, pure red. Between these stops the levels are blended.
private let warmthStops: [(warmth: Double, green: Double, blue: Double)] = [
    (0.0, 0.95, 0.80),
    (0.5, 0.65, 0.25),
    (0.8, 0.30, 0.00),
    (1.0, 0.00, 0.00),
]
/// On the built-in screen, 100% intensity lowers the backlight to this fraction of your normal brightness, but never
/// below `lowestBacklight` (0–1, like the brightness slider), so the screen can't switch off.
private let backlightAtFull: Float = 0.05
private let lowestBacklight: Float = 0.015
/// Screens whose backlight Dusk can't control (external displays) are dimmed through the gamma table instead,
/// down to this fraction at 100%.
private let dimAtFull = 0.25

/// How much one notch of a regular mouse wheel changes the intensity.
private let wheelStep = 0.05
/// How much one point of trackpad / smooth-mouse scrolling changes the intensity.
private let preciseStep = 0.0025

// MARK: - Screen filter (display gamma tables)

/// Tints each display through its own gamma table, so colour calibration is kept and the cursor is filtered too, and
/// dims the built-in screen with its backlight. macOS puts the original gamma tables back by itself when this process
/// exits, even if it crashes.
final class ScreenFilter {
    private struct Table { var r, g, b: [CGGammaValue] }
    private var originals: [CGDirectDisplayID: Table] = [:]
    /// Whether the filter is on. At 0% it's still on: no tint, but it keeps following the brightness.
    private(set) var isOn = false
    /// The intensity, kept while the filter is off so turning it back on returns to it.
    private(set) var intensity = 0.0
    /// How warm 100% is: 0 is a little warmer, 1 is pure red (see `warmthStops`). Set from the Max Warmth slider.
    var maxWarmth = 0.5

    private let backlight = Backlight()
    /// Your normal brightness while Dusk has the backlight turned down. Kept on disk so a crash can't lose it.
    private var savedBrightness = UserDefaults.standard.object(forKey: "normalBrightness") as? Float {
        didSet { UserDefaults.standard.set(savedBrightness, forKey: "normalBrightness") }
    }
    /// The backlight level Dusk last set or followed, to notice changes made outside Dusk.
    private var lastBrightness: Float?

    init() { captureOriginals() }

    /// Read every display's unfiltered gamma table. Call again when displays are added or removed.
    func captureOriginals() {
        CGDisplayRestoreColorSyncSettings()
        originals = [:]
        for display in Self.onlineDisplays() {
            let capacity = CGDisplayGammaTableCapacity(display)
            var r = [CGGammaValue](repeating: 0, count: Int(capacity)), g = r, b = r
            var count: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success, count > 0 else { continue }
            let n = Int(count)
            originals[display] = Table(r: Array(r[..<n]), g: Array(g[..<n]), b: Array(b[..<n]))
        }
    }

    func apply(_ t: Double, on: Bool) {
        intensity = t
        isOn = on
        updateBacklight()
        applyGamma()
    }

    /// Follows a brightness change made outside Dusk (brightness keys, Control Center, auto-brightness) while the filter
    /// is on, by moving the intensity to match it. The backlight itself is left alone, so a
    /// brightness animation that's still running isn't interrupted. Returns true if the intensity changed.
    func followBrightnessChange() -> Bool {
        guard isOn, let last = lastBrightness, let normal = savedBrightness, let now = backlight.brightness,
              abs(now - last) > 0.005 else { return false }
        lastBrightness = now
        // Brightness 0 just switches the screen off: leave Dusk as it is for when it comes back on.
        if now < 0.005 { return false }
        let t = Double((1 - now / normal) / (1 - backlightAtFull))
        if t <= 0 {
            // At or above your normal brightness: that's your new normal brightness, at 0%.
            savedBrightness = now
            intensity = 0
        } else {
            // Darker than 100% goes: stay at 100% and lower your normal brightness to match.
            if t > 1 { savedBrightness = now / backlightAtFull }
            intensity = min(t, 1)
        }
        applyGamma()
        return true
    }

    private func applyGamma() {
        guard isOn, intensity > 0 else { CGDisplayRestoreColorSyncSettings(); return }
        let backlit = backlight.display
        for (display, table) in originals {
            let (rs, gs, bs) = scales(intensity, dimmedByBacklight: display == backlit)
            let r = table.r.map { $0 * rs }, g = table.g.map { $0 * gs }, b = table.b.map { $0 * bs }
            CGSetDisplayTransferByTable(display, UInt32(r.count), r, g, b)
        }
    }

    /// The built-in screen is darkened with its backlight rather than the gamma table: dark pixels in front of a bright
    /// backlight leak light, which an XDR screen's dimming zones show as a patchy glow.
    private func updateBacklight() {
        guard isOn, backlight.display != nil else {
            if let saved = savedBrightness {
                backlight.setBrightness(saved)
                savedBrightness = nil
            }
            lastBrightness = nil
            return
        }
        if savedBrightness == nil { savedBrightness = backlight.brightness }
        guard let normal = savedBrightness else { return }
        let factor = 1 - (1 - backlightAtFull) * Float(intensity)
        let value = max(normal * factor, min(lowestBacklight, normal))
        backlight.setBrightness(value)
        lastBrightness = value
    }

    /// macOS resets gamma on wake, display changes and colour-profile changes. Put ours back if that happened.
    func reapplyIfReset() {
        guard isOn, intensity > 0 else { return }
        let backlit = backlight.display
        for (display, table) in originals {
            let (rs, _, bs) = scales(intensity, dimmedByBacklight: display == backlit)
            var r = [CGGammaValue](repeating: 0, count: table.r.count), g = r, b = r
            var count: UInt32 = 0
            CGGetDisplayTransferByTable(display, UInt32(r.count), &r, &g, &b, &count)
            guard count > 0, let lastR = table.r.last, let lastB = table.b.last else { continue }
            let i = Int(count) - 1
            // Blue is checked too: with a red Max Warmth a reset brings it back from 0 while red barely changes.
            if abs(r[i] - lastR * rs) > 0.01 || abs(b[i] - lastB * bs) > 0.01 { apply(intensity, on: true); return }
        }
    }

    /// Red, green and blue levels at intensity `t`: from no tint at 0 to the Max Warmth colour at 1.
    private func scales(_ t: Double, dimmedByBacklight: Bool) -> (r: CGGammaValue, g: CGGammaValue, b: CGGammaValue) {
        let (green, blue) = Self.colour(atWarmth: maxWarmth)
        let dim = dimmedByBacklight ? 1 : 1 - (1 - dimAtFull) * t
        return (CGGammaValue(dim),
                CGGammaValue(dim * (1 - (1 - green) * t)),
                CGGammaValue(dim * (1 - (1 - blue) * t)))
    }

    /// Green and blue at 100% for a Max Warmth value, blended between the nearest `warmthStops`.
    private static func colour(atWarmth warmth: Double) -> (green: Double, blue: Double) {
        let w = min(max(warmth, 0), 1)
        for (a, b) in zip(warmthStops, warmthStops.dropFirst()) where w <= b.warmth {
            let f = (w - a.warmth) / (b.warmth - a.warmth)
            return (a.green + (b.green - a.green) * f, a.blue + (b.blue - a.blue) * f)
        }
        return (0, 0)
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids[..<Int(count)])
    }
}

/// The built-in screen's real backlight, through the private DisplayServices framework the brightness keys use.
final class Backlight {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?

    init() {
        let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getFn = lib.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
        setFn = lib.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
    }

    /// The built-in display, if it's connected and its brightness can be read.
    var display: CGDirectDisplayID? {
        ScreenFilter.onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 && read($0) != nil }
    }

    var brightness: Float? { display.flatMap(read) }

    func setBrightness(_ value: Float) {
        if let display { _ = setFn?(display, value) }
    }

    private func read(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        return getFn?(display, &value) == 0 ? value : nil
    }
}

// MARK: - Level bubble

/// A small "73%" bubble just below the menu bar icon. Showing the level here instead of next to the icon
/// keeps the menu bar item's width fixed, so nothing in the menu bar shifts while scrolling.
final class LevelHUD {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 26),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    init() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        panel.contentView = background

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: background.centerYAnchor)])
    }

    func show(_ text: String, under icon: NSRect) {
        label.stringValue = text
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) }
        // Sit just under the menu bar (its bottom is the top of the visible frame), centred on the icon.
        let menuBarBottom = min(icon.minY, screen?.visibleFrame.maxY ?? icon.minY)
        var x = icon.midX - size.width / 2
        if let screen { x = min(max(x, screen.frame.minX + 4), screen.frame.maxX - size.width - 4) }
        panel.setFrameOrigin(NSPoint(x: x, y: menuBarBottom - size.height - 4))

        generation += 1
        let shown = generation
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, shown == self.generation else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { if shown == self.generation { self.panel.orderOut(nil) } })
        }
    }
}

// MARK: - Menu bar item

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let filter = ScreenFilter()
    private let defaults = UserDefaults.standard
    private let hud = LevelHUD()
    private var sigterm: DispatchSourceSignal?

    private let intensityHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let warmthHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warmthSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
    /// Checks for new versions once a day and installs them (Sparkle), using the feed and key in Info.plist.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                            userDriverDelegate: self)
    private let updateItem = NSMenuItem(title: "Check for Updates…",
                                        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                        keyEquivalent: "")
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["intensity": 0.4, "enabled": true, "maxWarmth": 0.5])

        // Start at login by default the first time Dusk runs; after that it's up to the menu toggle.
        if !defaults.bool(forKey: "loginItemSetUp") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginItemSetUp")
        }

        buildMenu()
        filter.maxWarmth = defaults.double(forKey: "maxWarmth")
        filter.apply(min(max(defaults.double(forKey: "intensity"), 0), 1), on: defaults.bool(forKey: "enabled"))
        intensityDidChange(showLabel: false)

        // On recent macOS the menu bar icons are drawn by another process, so scrolls over our icon go there.
        // A global monitor still sees them; the local one covers systems where they're delivered to this app.
        NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            _ = self?.handleScrollIfOverIcon(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            (self?.handleScrollIfOverIcon(event) ?? false) ? nil : event
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.filter.captureOriginals()
            self.filter.apply(self.filter.intensity, on: self.filter.isOn)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.filter.apply(self.filter.intensity, on: self.filter.isOn)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.filter.reapplyIfReset()
        }
        // Follow brightness changes made outside Dusk (brightness keys, Control Center, auto-brightness). Added in the
        // common run loop modes so an open menu keeps up too.
        let follow = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.filter.followBrightnessChange() else { return }
            self.intensityDidChange(showLabel: false)
        }
        RunLoop.main.add(follow, forMode: .common)

        // Treat `killall Dusk` like Quit, so the brightness gets put back.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal colours and your normal brightness. Not saved as "off", so Dusk is back on next launch.
        filter.apply(filter.intensity, on: false)
    }

    // MARK: Scrolling

    /// Uses the scroll and returns true if the pointer is over our menu bar icon.
    private func handleScrollIfOverIcon(_ event: NSEvent) -> Bool {
        guard let icon = iconFrame else { return false }
        let p = NSEvent.mouseLocation
        // Take the full height of the menu bar, so a pointer pushed against the top edge still counts.
        let top = statusItem.button?.window?.screen?.frame.maxY ?? icon.maxY
        guard p.x >= icon.minX, p.x <= icon.maxX, p.y >= icon.minY - 8, p.y <= top else { return false }
        handleScroll(event)
        return true
    }

    private func handleScroll(_ event: NSEvent) {
        // Ignore trackpad momentum so a flick doesn't overshoot.
        guard event.momentumPhase.isEmpty else { return }
        // Follow the direction the fingers / wheel physically moved, whatever the natural-scrolling setting.
        var dy = Double(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { dy = -dy }
        guard dy != 0 else { return }
        // Catch up with a brightness-key change first, so the scroll carries on from it.
        if filter.followBrightnessChange() { intensityDidChange(showLabel: false) }
        let delta = event.hasPreciseScrollingDeltas ? dy * preciseStep : (dy > 0 ? wheelStep : -wheelStep)
        let before = Int((filter.intensity * 100).rounded())
        setIntensity(filter.intensity + delta, showLabel: true)
        // A light tick on the trackpad every 5%, like the notches of a dial.
        if before / 5 != Int((filter.intensity * 100).rounded()) / 5 {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    /// Sets the intensity, turning the filter on if it was off.
    private func setIntensity(_ value: Double, showLabel: Bool) {
        filter.apply(min(max(value, 0), 1), on: true)
        intensityDidChange(showLabel: showLabel)
    }

    /// Saves the intensity and on/off state and brings the icon, bubble and open menu up to date with them.
    private func intensityDidChange(showLabel: Bool) {
        let t = filter.intensity
        defaults.set(t, forKey: "intensity")
        defaults.set(filter.isOn, forKey: "enabled")

        statusItem.button?.image = NSImage(systemSymbolName: filter.isOn ? "sun.horizon.fill" : "sun.horizon",
                                           accessibilityDescription: "Dusk")
        if showLabel, let icon = iconFrame { hud.show(percentText(t), under: icon) }
        if menuIsOpen { refreshMenu() } // so the open menu's slider moves along
    }

    /// The icon's frame in screen coordinates.
    private var iconFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func percentText(_ t: Double) -> String {
        "\(Int((t * 100).rounded()))%"
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        for header in [intensityHeader, warmthHeader] { header.isEnabled = false }
        menu.addItem(intensityHeader)
        menu.addItem(sliderItem(slider, action: #selector(sliderChanged)))
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(warmthHeader)
        menu.addItem(sliderItem(warmthSlider, action: #selector(warmthChanged)))
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        updateItem.target = updater
        menu.addItem(updateItem)
        menu.addItem(NSMenuItem(title: "Quit Dusk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func sliderItem(_ slider: NSSlider, action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        slider.frame = NSRect(x: 18, y: 4, width: 184, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = action
        container.addSubview(slider)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func refreshMenu() {
        intensityHeader.title = "Intensity: \(percentText(filter.intensity))"
        slider.doubleValue = filter.intensity * 100
        toggleItem.title = filter.isOn ? "Turn Off" : "Turn On"
        warmthHeader.title = "Max Warmth: " + (filter.maxWarmth >= 1 ? "Pure Red" : percentText(filter.maxWarmth))
        warmthSlider.doubleValue = filter.maxWarmth * 100
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        refreshMenu()
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    @objc private func sliderChanged() {
        setIntensity(slider.doubleValue / 100, showLabel: false)
    }

    @objc private func warmthChanged() {
        filter.maxWarmth = warmthSlider.doubleValue / 100
        defaults.set(filter.maxWarmth, forKey: "maxWarmth")
        filter.apply(filter.intensity, on: filter.isOn)
        refreshMenu()
    }

    @objc private func toggle() {
        filter.apply(filter.intensity, on: !filter.isOn)
        intensityDidChange(showLabel: false)
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }
}

// MARK: - Updates

/// Dusk lives in the menu bar, so an update window opened in the background could go unnoticed. A scheduled check
/// that finds an update shows it straight away only around launch; otherwise the menu item says an update is ready.
extension AppDelegate: SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate { updateItem.title = "Update to \(update.displayVersionString)…" }
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateItem.title = "Check for Updates…"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
