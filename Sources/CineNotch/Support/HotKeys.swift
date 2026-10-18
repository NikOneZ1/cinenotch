import Carbon.HIToolbox
import Foundation

/// Keyboard shortcuts that work from any app: ⌃⌥⌘ plus a key. They go through Carbon's hot keys,
/// which need no permission and don't reach the app in front. ⌃⌥⌘ keeps clear of the system's and
/// window managers' shortcuts (⌃⌥Space switches input sources, ⌃⌥ arrows move windows in Rectangle).
@MainActor
final class HotKeys: ObservableObject {
    enum Action: UInt32, CaseIterable {
        case togglePlay = 1, skipBack, skipForward, toggleIsland

        var title: String {
            switch self {
            case .togglePlay: return "Play or pause"
            case .skipBack: return "Back 10 seconds"
            case .skipForward: return "Forward 10 seconds"
            case .toggleIsland: return "Open or close the island"
            }
        }

        /// Physical keys, so they're the same on every keyboard layout.
        fileprivate var keyCode: Int {
            switch self {
            case .togglePlay: return kVK_ANSI_P
            case .skipBack: return kVK_ANSI_LeftBracket
            case .skipForward: return kVK_ANSI_RightBracket
            case .toggleIsland: return kVK_ANSI_O
            }
        }

        var shortcut: String {
            let key: String
            switch self {
            case .togglePlay: key = "P"
            case .skipBack: key = "["
            case .skipForward: key = "]"
            case .toggleIsland: key = "O"
            }
            return "⌃⌥⌘" + key
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? register() : unregister()
            Log.info("keyboard shortcuts: \(isEnabled)")
        }
    }
    var perform: (Action) -> Void = { _ in }

    private static let enabledKey = "hotKeysEnabled"
    private static let signature: OSType = 0x434E_6368 // "CNch"
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // Carbon calls back on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let context, let action = Action(rawValue: id.id) else { return OSStatus(eventNotHandledErr) }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKeys.perform(action) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if isEnabled { register() }
    }

    private func register() {
        guard refs.isEmpty else { return }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(action.keyCode), modifiers, EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
            } else {
                // Another app holds this one.
                Log.info("keyboard shortcuts: \(action.shortcut) is taken (\(status))")
            }
        }
    }

    private func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}
