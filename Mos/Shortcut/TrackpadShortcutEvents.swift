import Cocoa

/// Build the entire pair before posting either event. A private source avoids
/// changing the combined hardware modifier state used by Mos's event taps.
enum TrackpadShortcutEvents {
    static func make(code: CGKeyCode, marker: Int64) -> [CGEvent] {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return [] }
        down.flags = .maskCommand
        up.flags = []
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        }
        return [down, up]
    }
}
