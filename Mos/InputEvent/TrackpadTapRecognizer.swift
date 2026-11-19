import Foundation

/// A complete snapshot for one device, including any contacts ending in this frame.
/// Adapters must use a monotonic clock and stable contact identities.
struct TrackpadTouchFrame {
    let deviceID: AnyHashable
    let timestamp: TimeInterval
    let touches: [TrackpadTouch]
}

struct TrackpadTouch {
    enum Phase {
        case began, moved, stationary, ended, cancelled

        var isActive: Bool {
            switch self {
            case .began, .moved, .stationary: return true
            case .ended, .cancelled: return false
            }
        }
    }

    let identity: AnyHashable
    let position: CGPoint
    let phase: Phase
    var isResting = false
}

struct TrackpadTap: Equatable {
    let deviceID: AnyHashable
    let fingerCount: Int
}

/// Pure recognition only. Creating this object does not install any input listener.
/// Each contact sequence produces at most one result, after its last finger lifts.
struct TrackpadTapRecognizer {
    struct Configuration {
        var maximumDuration: TimeInterval = 0.30
        var maximumArrivalSpread: TimeInterval = 0.08
        var minimumOverlap: TimeInterval = 0.025
        /// Distance on the normalized trackpad surface, measured per finger.
        var maximumMovement: CGFloat = 0.035
    }

    private struct Sequence {
        let startedAt: TimeInterval
        var lastTimestamp: TimeInterval
        var anchors: [AnyHashable: CGPoint] = [:]
        var previousActive: Set<AnyHashable> = []
        var peakFingerCount = 0
        var peakStartedAt: TimeInterval
        var peakEndedAt: TimeInterval?
        var rejected = false
    }

    let configuration: Configuration
    private var sequences: [AnyHashable: Sequence] = [:]

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func process(_ frame: TrackpadTouchFrame) -> TrackpadTap? {
        let activeTouches = frame.touches.filter { $0.phase.isActive && !$0.isResting }
        guard var sequence = sequences[frame.deviceID] ?? makeSequence(frame, activeTouches: activeTouches) else {
            return nil
        }

        if !frame.timestamp.isFinite || frame.timestamp < sequence.lastTimestamp ||
            frame.timestamp - sequence.startedAt > configuration.maximumDuration {
            sequence.rejected = true
        }
        sequence.lastTimestamp = frame.timestamp

        var identities = Set<AnyHashable>()
        for touch in frame.touches {
            if !identities.insert(touch.identity).inserted || touch.phase == .cancelled {
                sequence.rejected = true
            }
            if touch.isResting {
                // A resting thumb may be ignored; a participating finger becoming
                // resting is not a reliable release and cancels this candidate.
                if sequence.anchors[touch.identity] != nil { sequence.rejected = true }
                continue
            }
            guard touch.position.x.isFinite, touch.position.y.isFinite,
                  (0...1).contains(touch.position.x), (0...1).contains(touch.position.y) else {
                sequence.rejected = true
                continue
            }

            if let anchor = sequence.anchors[touch.identity] {
                let dx = touch.position.x - anchor.x
                let dy = touch.position.y - anchor.y
                if dx * dx + dy * dy > configuration.maximumMovement * configuration.maximumMovement {
                    sequence.rejected = true
                }
                if touch.phase.isActive && !sequence.previousActive.contains(touch.identity) {
                    sequence.rejected = true // A released finger returned within the sequence.
                }
            } else if touch.phase.isActive {
                sequence.anchors[touch.identity] = touch.position
                if touch.phase != .began ||
                    frame.timestamp - sequence.startedAt > configuration.maximumArrivalSpread {
                    sequence.rejected = true
                }
            } else {
                sequence.rejected = true // An unmatched release means the stream was incomplete.
            }
        }

        let active = Set(activeTouches.map { $0.identity })
        if active.count > sequence.peakFingerCount {
            sequence.peakFingerCount = active.count
            sequence.peakStartedAt = frame.timestamp
            sequence.peakEndedAt = nil
        } else if active.count < sequence.peakFingerCount && sequence.peakEndedAt == nil {
            sequence.peakEndedAt = frame.timestamp
        }
        if sequence.anchors.count > 4 { sequence.rejected = true }
        sequence.previousActive = active

        guard active.isEmpty else {
            sequences[frame.deviceID] = sequence
            return nil
        }
        sequences.removeValue(forKey: frame.deviceID)
        let overlap = (sequence.peakEndedAt ?? frame.timestamp) - sequence.peakStartedAt
        guard !sequence.rejected, (3...4).contains(sequence.peakFingerCount),
              sequence.anchors.count == sequence.peakFingerCount,
              overlap >= configuration.minimumOverlap else {
            return nil
        }
        return TrackpadTap(deviceID: frame.deviceID, fingerCount: sequence.peakFingerCount)
    }

    /// Use when a click, drag, scroll, or another gesture invalidates a candidate.
    /// Keep it rejected until release, so the remaining fingers cannot start a tap.
    mutating func cancelCandidates() {
        for deviceID in Array(sequences.keys) {
            sequences[deviceID]?.rejected = true
        }
    }

    mutating func reset(deviceID: AnyHashable) {
        sequences.removeValue(forKey: deviceID)
    }

    mutating func reset() {
        sequences.removeAll()
    }

    private func makeSequence(_ frame: TrackpadTouchFrame, activeTouches: [TrackpadTouch]) -> Sequence? {
        guard !activeTouches.isEmpty else { return nil }
        return Sequence(startedAt: frame.timestamp, lastTimestamp: frame.timestamp,
                        peakStartedAt: frame.timestamp)
    }
}
