import AppKit
import ApplicationServices

/// Notification-driven, allowlisted observation. No key logging, clipboard
/// reads, polling timer, or observation of non-allowlisted applications.
@MainActor
public final class MacOSFocusedTextObserver: NSObject {
    public var onChange: (@MainActor () -> Void)?
    public var onUnavailable: (@MainActor () -> Void)?
    private var enabled = false
    private var allowedApplications: Set<String> = []
    private var observer: AXObserver?
    private var element: AXUIElement?

    public override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    public func configure(enabled: Bool, allowedApplications: Set<String>) {
        self.enabled = enabled
        self.allowedApplications = allowedApplications
        activeApplicationChanged()
    }

    @objc private func activeApplicationChanged() {
        detach()
        onUnavailable?()
        guard enabled, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier,
              allowedApplications.contains(identifier) else { return }
        var result: AXObserver?
        guard AXObserverCreate(app.processIdentifier, Self.callback, &result) == .success,
              let result else { return }
        observer = result
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(result, application, kAXFocusedUIElementChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
        focusedElementChanged()
    }

    private func focusedElementChanged() {
        guard enabled, let observer,
              let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              allowedApplications.contains(id) else { onUnavailable?(); return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { onUnavailable?(); return }
        let focused = value as! AXUIElement
        if element == nil || !CFEqual(element!, focused) {
            if let element {
                for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                    _ = AXObserverRemoveNotification(observer, element, notification as CFString)
                }
            }
            element = focused
            let context = Unmanaged.passUnretained(self).toOpaque()
            for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                _ = AXObserverAddNotification(observer, focused, notification as CFString, context)
            }
        }
        onChange?()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        element = nil
    }

    private static let callback: AXObserverCallback = { _, _, _, context in
        guard let context else { return }
        let owner = Unmanaged<MacOSFocusedTextObserver>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in owner.focusedElementChanged() }
    }
}
