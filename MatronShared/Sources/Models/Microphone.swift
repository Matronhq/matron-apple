import Foundation

/// An audio input a voice note can record from: the built-in microphone,
/// AirPods, a USB headset. `id` is the platform's stable identifier (the
/// port UID on iOS, the capture device's unique ID on the Mac), so a
/// remembered pick survives a relaunch and finds the same device again.
public struct Microphone: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
