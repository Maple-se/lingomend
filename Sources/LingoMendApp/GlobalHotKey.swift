import Carbon
import Foundation

@MainActor
final class GlobalHotKey {
    private let onTrigger: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(onTrigger: @escaping @MainActor () -> Void) {
        self.onTrigger = onTrigger
    }

    func register() -> Bool {
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

        let identifier = EventHotKeyID(signature: 0x4C4D454E, id: 1)
        let keyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(controlKey | optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return keyStatus == noErr
    }

    private static let handleEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        Task { @MainActor in hotKey.onTrigger() }
        return noErr
    }
}
