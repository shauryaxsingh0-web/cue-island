import AppKit
import Carbon.HIToolbox

@MainActor
final class PresentationShortcuts {
    private enum Shortcut: UInt32, CaseIterable {
        case toggle = 1
        case exit

        var keyCode: UInt32 {
            switch self {
            case .toggle: return UInt32(kVK_Space)
            case .exit: return UInt32(kVK_Escape)
            }
        }
    }

    private static let signature: OSType = 0x43554953 // CUIS
    private let onToggle: () -> Void
    private let onExit: () -> Void
    private var handler: EventHandlerRef?
    private var registered: [Shortcut: EventHotKeyRef] = [:]
    private var held: Set<Shortcut> = []
    private var localMonitor: Any?

    init(onToggle: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onExit = onExit
    }

    isolated deinit {
        stop()
    }

    /// Starts a presentation session. Returns false if a key works only inside the app.
    @discardableResult
    func start() -> Bool {
        stop()
        let types = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let target = GetApplicationEventTarget()
        let status = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            // Events targeted to the application's Carbon event queue run on its main thread.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<PresentationShortcuts>.fromOpaque(context).takeUnretainedValue()
                return owner.receive(event)
            }
        }, types.count, types, Unmanaged.passUnretained(self).toOpaque(), &handler)

        if status == noErr {
            for shortcut in Shortcut.allCases {
                var reference: EventHotKeyRef?
                let identifier = EventHotKeyID(signature: Self.signature, id: shortcut.rawValue)
                let result = RegisterEventHotKey(shortcut.keyCode, 0, identifier, target,
                                                 UInt32(kEventHotKeyExclusive), &reference)
                if result == noErr, let reference {
                    registered[shortcut] = reference
                }
            }
        }

        // System hotkeys consume hardware events. Also handle key events delivered
        // directly to our app, including accessibility and software keyboards.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let shortcut = Shortcut.allCases.first(where: { $0.keyCode == UInt32(event.keyCode) })
                  else { return event }
            if !event.isARepeat { self.trigger(shortcut) }
            return nil
        }
        return registered.count == Shortcut.allCases.count
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        for reference in registered.values { UnregisterEventHotKey(reference) }
        registered.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        held.removeAll()
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard status == noErr, identifier.signature == Self.signature,
              let shortcut = Shortcut(rawValue: identifier.id),
              registered[shortcut] != nil else { return OSStatus(eventNotHandledErr) }

        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            held.remove(shortcut)
        } else if held.insert(shortcut).inserted {
            trigger(shortcut)
        }
        return noErr
    }

    private func trigger(_ shortcut: Shortcut) {
        switch shortcut {
        case .toggle: onToggle()
        case .exit: onExit()
        }
    }
}
