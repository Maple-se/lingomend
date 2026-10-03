import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private let onTrigger: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let identifier: UInt32

    init(keyCode: UInt32 = UInt32(kVK_ANSI_L), identifier: UInt32 = 1,
         onTrigger: @escaping @MainActor () -> Void) {
        self.keyCode = keyCode
        self.identifier = identifier
        self.onTrigger = onTrigger
    }

    func register() -> Bool {
        if hotKeyRef != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard handlerStatus == noErr else { return false }

        let identifier = EventHotKeyID(signature: 0x4C4D454E, id: identifier)
        let keyStatus = RegisterEventHotKey(
            keyCode,
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if keyStatus != noErr { unregister() }
        return keyStatus == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil; handlerRef = nil
    }

    private static let handleEvent: EventHandlerUPP = { _, event, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        var identifier = EventHotKeyID()
        guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else {
            return OSStatus(eventNotHandledErr)
        }
        return MainActor.assumeIsolated {
            guard identifier.signature == 0x4C4D454E, identifier.id == hotKey.identifier else {
                return OSStatus(eventNotHandledErr)
            }
            hotKey.onTrigger()
            return noErr
        }
    }
}
