import Foundation

/// Value snapshot of the private contact states. No framework pointers survive a callback.
struct TrackpadContact {
    let identity: Int32
    let state: Int32
    let position: CGPoint
}

enum TrackpadAction: Equatable {
    case copy, paste
}

/// Serial, main-thread input state shared by Mos and the device test harness.
/// A new generation invalidates every queued frame from a previous listener.
struct TrackpadTapInput {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false
    private var recognizer = TrackpadTapRecognizer()
    private var previous: [UInt: Set<Int32>] = [:]
    private var armed = Set<UInt>()
    private var earliestArrival: TimeInterval = 0

    @discardableResult
    mutating func start(notBefore timestamp: TimeInterval = 0) -> UInt64 {
        stop()
        earliestArrival = timestamp
        isActive = true
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isActive = false
        recognizer.reset()
        previous.removeAll()
        armed.removeAll()
    }

    mutating func cancel() {
        recognizer.cancelCandidates()
        // Also guard against cancellation arriving before its first contact frame.
        // Do not re-arm until a complete idle snapshot is received.
        armed.removeAll()
    }

    mutating func process(device: UInt, contacts: [TrackpadContact],
                          timestamp: TimeInterval, receivedAt: TimeInterval,
                          generation: UInt64) -> TrackpadAction? {
        guard isActive, generation == self.generation else { return nil }
        // Native timestamps are device-relative and only measure tap duration.
        // Compare listener startup with the host callback-arrival clock instead.
        guard timestamp.isFinite, receivedAt.isFinite else { cancel(); return nil }
        guard receivedAt >= earliestArrival else { return nil }
        let prior = previous[device] ?? []
        var active = Set<Int32>()
        let touches = contacts.compactMap { contact -> TrackpadTouch? in
            let phase: TrackpadTouch.Phase
            switch contact.state {
            case 3, 4:
                active.insert(contact.identity)
                if prior.contains(contact.identity) { phase = .moved }
                else if armed.contains(device) { phase = .began }
                else { phase = .stationary }
            case 5:
                guard prior.contains(contact.identity) else { return nil }
                phase = .ended
            default:
                // Out-of-range states are invalid data, not a successful release.
                guard (0...7).contains(contact.state) else {
                    return TrackpadTouch(identity: contact.identity, position: contact.position, phase: .cancelled)
                }
                return nil // Hover / lingering contacts.
            }
            return TrackpadTouch(identity: contact.identity, position: contact.position, phase: phase)
        }
        previous[device] = active.isEmpty ? nil : active
        if active.isEmpty { armed.insert(device) }
        guard !touches.isEmpty || !prior.isEmpty else { return nil }
        guard let tap = recognizer.process(TrackpadTouchFrame(
            deviceID: device, timestamp: timestamp, touches: touches)) else { return nil }
        return tap.fingerCount == 3 ? .copy : .paste
    }
}
