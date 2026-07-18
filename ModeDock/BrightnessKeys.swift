import AppKit
import ApplicationServices
import DisplayKit

/// Takes over the keyboard's brightness keys so they change every screen, including monitors
/// macOS can't dim. Needs the Accessibility permission to see and swallow the keys.
@MainActor
final class BrightnessKeys {
    /// NX_KEYTYPE_BRIGHTNESS_UP and NX_KEYTYPE_BRIGHTNESS_DOWN in system-defined events.
    private static let upKey = 2
    private static let downKey = 3
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS: media and brightness keys.
    private static let auxControlButtons: Int16 = 8
    /// NX_SYSDEFINED, which CGEventType doesn't name.
    private static let systemDefined: UInt32 = 14
    /// Some keyboards send the brightness keys as ordinary key presses with these codes.
    private static let upKeyCode: Int64 = 144
    private static let downKeyCode: Int64 = 145
    private static let log = AppLog("BrightnessKeys")

    /// Called on each press and key repeat, with +1 for up and -1 for down.
    var onPress: (Int) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?
    /// When the keyboard last sent a brightness key as a key code. Keyboards that do also send
    /// the system event for the same press, which is then swallowed without acting twice.
    private var lastKeyCodePress: Date?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.brightnessKeysAllScreens) }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the system prompt that leads to Privacy & Security → Accessibility.
    static func requestAccess() {
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 won't read from a global var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Starts or stops the tap to match the setting. Until access is granted it keeps checking,
    /// so the keys start working as soon as the user allows ModeDock.
    func update() {
        guard Self.isEnabled else {
            stop()
            return
        }
        guard tap == nil else { return }
        if !start() {
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, Self.isEnabled else { return }
                    if self.start() {
                        self.retry?.invalidate()
                        self.retry = nil
                    }
                }
            }
        }
    }

    private func start() -> Bool {
        guard Self.isTrusted else {
            Self.log.notice("Not trusted for Accessibility yet")
            return false
        }
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << Self.systemDefined | CGEventMask(1) << CGEventType.keyDown.rawValue
                | CGEventMask(1) << CGEventType.keyUp.rawValue,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<BrightnessKeys>.fromOpaque(info).takeUnretainedValue()
                // The tap is on the main run loop, so this runs on the main thread.
                let handled = MainActor.assumeIsolated { keys.handle(type, event) }
                return handled ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else {
            Self.log.error("Couldn't create the event tap")
            return false
        }
        Self.log.notice("Event tap started")
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func stop() {
        retry?.invalidate()
        retry = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Whether the event was a brightness key, which is then kept from macOS.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        // macOS turns a slow tap off; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if type == .keyDown || type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard code == Self.upKeyCode || code == Self.downKeyCode else { return false }
            if type == .keyDown {
                lastKeyCodePress = .now
                onPress(code == Self.upKeyCode ? 1 : -1)
            }
            return true
        }
        guard type.rawValue == Self.systemDefined, let nsEvent = NSEvent(cgEvent: event),
            nsEvent.subtype.rawValue == Self.auxControlButtons
        else { return false }
        let key = (nsEvent.data1 & 0xFFFF_0000) >> 16
        guard key == Self.upKey || key == Self.downKey else { return false }
        let isDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
        let keyboardSendsKeyCodes = lastKeyCodePress.map { Date.now.timeIntervalSince($0) < 1 } ?? false
        if isDown, !keyboardSendsKeyCodes { onPress(key == Self.upKey ? 1 : -1) }
        return true
    }
}
