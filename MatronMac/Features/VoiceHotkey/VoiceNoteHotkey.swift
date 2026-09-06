import AppKit
import Carbon.HIToolbox
import Foundation
import Observation

/// The key a global press of which starts / stops a voice note from
/// anywhere on the Mac — Matron frontmost or not. Persisted as its raw
/// value under `storageKey`; `.off` disables the hotkey entirely.
///
/// Only function keys are offered: a plain letter would swallow typing in
/// every other app, and modifier combos are what the Dictation and
/// Spotlight defaults already use. F5 is the default because it is the
/// mic-glyph key on Apple keyboards — with the one catch that macOS binds
/// it to system Dictation until that shortcut is turned off (Settings →
/// Keyboard → Dictation), which the Device settings caption says.
enum VoiceNoteHotkeyKey: String, CaseIterable, Identifiable {
    case off
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10
    case f11, f12, f13, f14, f15, f16, f17, f18, f19

    static let storageKey = "VoiceNoteHotkey"
    static let `default`: VoiceNoteHotkeyKey = .f5

    var id: String { rawValue }

    var label: String { self == .off ? "Off" : rawValue.uppercased() }

    /// Carbon virtual key code (`kVK_F5` etc.), nil for `.off`.
    var carbonKeyCode: UInt32? {
        switch self {
        case .off: return nil
        case .f1: return UInt32(kVK_F1)
        case .f2: return UInt32(kVK_F2)
        case .f3: return UInt32(kVK_F3)
        case .f4: return UInt32(kVK_F4)
        case .f5: return UInt32(kVK_F5)
        case .f6: return UInt32(kVK_F6)
        case .f7: return UInt32(kVK_F7)
        case .f8: return UInt32(kVK_F8)
        case .f9: return UInt32(kVK_F9)
        case .f10: return UInt32(kVK_F10)
        case .f11: return UInt32(kVK_F11)
        case .f12: return UInt32(kVK_F12)
        case .f13: return UInt32(kVK_F13)
        case .f14: return UInt32(kVK_F14)
        case .f15: return UInt32(kVK_F15)
        case .f16: return UInt32(kVK_F16)
        case .f17: return UInt32(kVK_F17)
        case .f18: return UInt32(kVK_F18)
        case .f19: return UInt32(kVK_F19)
        }
    }
}

/// What one press should do. Pure, so the composer's reaction and the
/// "no chat open" refusal are pinned without a key or a mic.
enum VoiceNoteHotkeyAction: Equatable {
    case start
    case stopAndSend
    case refuse

    /// `isLocked`: the app lock is an overlay — the composer stays mounted
    /// behind it — so the key must refuse on the lock itself, or a
    /// passer-by could record and send into the last chat.
    /// `mediaAvailable`: a composer that hides its mic button must not
    /// grow one through the keyboard.
    static func resolve(isRecording: Bool, hasComposer: Bool,
                        isLocked: Bool = false, mediaAvailable: Bool = true) -> VoiceNoteHotkeyAction {
        guard hasComposer, !isLocked, mediaAvailable else { return .refuse }
        return isRecording ? .stopAndSend : .start
    }
}

/// The seam between the global hotkey and the Mac composers on screen.
/// Composers `claim` the bus (on appear, and whenever their window becomes
/// key) and `release` it on disappear; a release only clears its own
/// claim, because a chat switch mounts the successor BEFORE the outgoing
/// composer disappears. The hotkey bumps `pressCount` and stamps
/// `pressTarget` with the claimant, so with several windows open exactly
/// one composer — the one in the key window — drives its recorder (and the
/// recording pill, error path and upload are the ones a mouse-started
/// note uses). The composer publishes `recordingStart` back so the
/// floating indicator follows every recording, however it began.
@Observable @MainActor
final class VoiceNoteCommandBus {
    private(set) var pressCount = 0
    /// The composer the latest press is addressed to; only it reacts.
    private(set) var pressTarget: UUID?
    private(set) var activeComposerID: UUID?
    var recordingStart: Date?

    var hasActiveComposer: Bool { activeComposerID != nil }

    func claim(_ id: UUID) { activeComposerID = id }

    func release(_ id: UUID) {
        if activeComposerID == id { activeComposerID = nil }
    }

    func press() {
        pressTarget = activeComposerID
        pressCount &+= 1
    }

    /// The sounds are the only feedback when Matron is behind another
    /// window: a rising tick to start, a soft pop on send, the alert
    /// sound for a press that can't do anything.
    static func playStartSound() { NSSound(named: "Tink")?.play() }
    static func playStopSound() { NSSound(named: "Pop")?.play() }
    static func playRefuseSound() { NSSound.beep() }
}

/// Carbon global hotkey registration. `RegisterEventHotKey` delivers the
/// press to this process whichever app is frontmost and needs no
/// Accessibility permission — unlike an `NSEvent` global monitor. One key
/// at a time; `register(.off)` (or deinit) releases it.
@MainActor
final class VoiceNoteHotkeyRegistrar {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: @MainActor () -> Void
    /// 'MTRN' — the signature Carbon hands back with the event so the
    /// handler can ignore hot keys that aren't ours.
    private static let signature: OSType = 0x4D54_524E
    private static let hotKeyID: UInt32 = 1

    init(onPress: @escaping @MainActor () -> Void) {
        self.onPress = onPress
    }

    func register(_ key: VoiceNoteHotkeyKey) {
        unregister()
        guard let keyCode = key.carbonKeyCode else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    var id = EventHotKeyID()
                    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                      nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                    guard id.signature == VoiceNoteHotkeyRegistrar.signature,
                          id.id == VoiceNoteHotkeyRegistrar.hotKeyID else { return OSStatus(eventNotHandledErr) }
                    let registrar = Unmanaged<VoiceNoteHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                    // Carbon calls on the main thread; hop through the actor
                    // formally rather than assume it.
                    Task { @MainActor in registrar.onPress() }
                    return noErr
                },
                1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
            guard status == noErr else { return }
        }
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        RegisterEventHotKey(keyCode, 0, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
