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
    private var readingElement: AXUIElement?

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

    /// Read-only browser/PDF selections may be owned by a parent rather than AX focus.
    /// Subscribe only to the source explicitly captured for the current request.
    public func observeReadingSelection(from reader: MacOSReadingSelectionReader) {
        observeSource(reader.capturedElement)
    }

    public func observeWritingSelection(from reader: MacOSAccessibilityTextReader) {
        observeSource(reader.capturedElement)
    }

    private func observeSource(_ source: AXUIElement?) {
        guard enabled, let observer, let source,
              element == nil || !CFEqual(element!, source) else { return }
        if let readingElement {
            for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                _ = AXObserverRemoveNotification(observer, readingElement, notification as CFString)
            }
        }
        readingElement = source
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            _ = AXObserverAddNotification(observer, source, notification as CFString, context)
        }
    }

    @objc private func activeApplicationChanged() {
        detach()
        guard enabled else { return }
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              let identifier = app.bundleIdentifier,
              allowedApplications.contains(identifier) else { onUnavailable?(); return }
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
              let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              allowedApplications.contains(id) else { onUnavailable?(); return }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var value: CFTypeRef?
        let code = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = (code == .success ? AXEditorAccess.element(value) : nil)
            ?? AXEditorAccess.element(AXEditorAccess.attribute(application, kAXFocusedUIElementAttribute)) else {
            // A missing focus attribute is not proof of a user focus change.
            // Let the session revalidate its addressed source and classify it.
            onChange?(); return
        }
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
        readingElement = nil
    }

    private static let callback: AXObserverCallback = { _, _, notification, context in
        guard let context else { return }
        let owner = Unmanaged<MacOSFocusedTextObserver>.fromOpaque(context).takeUnretainedValue()
        let isFocus = notification as String == kAXFocusedUIElementChangedNotification
        Task { @MainActor in
            if isFocus { owner.focusedElementChanged() }
            else { owner.onChange?() }
        }
    }
}
