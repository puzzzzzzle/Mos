import XCTest
@testable import Mos_Debug

final class TrackpadTapRecognizerTests: XCTestCase {
    private var recognizer = TrackpadTapRecognizer()

    private func touch(_ id: Int, _ phase: TrackpadTouch.Phase = .began,
                       x: CGFloat? = nil, y: CGFloat = 0.5, resting: Bool = false) -> TrackpadTouch {
        TrackpadTouch(identity: id, position: CGPoint(x: x ?? CGFloat(id) * 0.15, y: y), phase: phase, isResting: resting)
    }

    @discardableResult
    private func frame(_ time: TimeInterval, _ touches: [TrackpadTouch], device: String = "built-in") -> TrackpadTap? {
        recognizer.process(TrackpadTouchFrame(deviceID: device, timestamp: time, touches: touches))
    }

    private func chord(_ count: Int, phase: TrackpadTouch.Phase = .began) -> [TrackpadTouch] {
        (1...count).map { touch($0, phase, x: CGFloat($0) * 0.15) }
    }

    func testThreeFingerTapOnlyEmitsOnceAfterRelease() {
        XCTAssertNil(frame(0, chord(3)))
        XCTAssertNil(frame(0.05, chord(3, phase: .stationary)))
        XCTAssertEqual(frame(0.10, chord(3, phase: .ended)), TrackpadTap(deviceID: "built-in", fingerCount: 3))
        XCTAssertNil(frame(0.11, []))
        XCTAssertNil(frame(0.12, chord(3, phase: .ended)))
    }

    func testStaggeredFourFingerTapNeverEmitsThree() {
        XCTAssertNil(frame(0, [touch(1)]))
        XCTAssertNil(frame(0.01, [touch(1, .stationary), touch(2), touch(3)]))
        XCTAssertNil(frame(0.03, chord(3, phase: .stationary) + [touch(4)]))
        XCTAssertNil(frame(0.08, chord(3, phase: .stationary) + [touch(4, .ended)]))
        XCTAssertEqual(frame(0.12, []), TrackpadTap(deviceID: "built-in", fingerCount: 4))
    }

    func testFiveFingersRejectsEntireSequenceInsteadOfFallingBackToThree() {
        frame(0, chord(5))
        frame(0.04, chord(3, phase: .stationary))
        XCTAssertNil(frame(0.10, []))
    }

    func testOneAndTwoFingersDoNotTrigger() {
        frame(0, chord(1))
        XCTAssertNil(frame(0.1, []))
        frame(1, chord(2))
        XCTAssertNil(frame(1.1, []))
    }

    func testLongPressDoesNotTrigger() {
        frame(0, chord(3))
        XCTAssertNil(frame(0.31, []))
    }

    func testMovementThatReturnsToOriginStillRejectsTap() {
        frame(0, chord(3))
        frame(0.04, [touch(1, .moved, x: 0.3)] + Array(chord(3, phase: .stationary).dropFirst()))
        frame(0.08, chord(3, phase: .moved))
        XCTAssertNil(frame(0.10, []))
    }

    func testOppositeFingerMovementCannotCancelOut() {
        frame(0, chord(3))
        frame(0.05, [touch(1, .moved, x: 0.25), touch(2, .moved, x: 0.20), touch(3, .stationary, x: 0.45)])
        XCTAssertNil(frame(0.10, []))
    }

    func testMovementInFinalReleaseFrameAlsoRejectsTap() {
        frame(0, chord(3))
        XCTAssertNil(frame(0.10, [touch(1, .ended, x: 0.4)] + Array(chord(3, phase: .ended).dropFirst())))
    }

    func testSmallFingerMovementAllowsTap() {
        frame(0, chord(3))
        frame(0.04, [touch(1, .moved, x: 0.17)] + Array(chord(3, phase: .stationary).dropFirst()))
        XCTAssertEqual(frame(0.10, [])?.fingerCount, 3)
    }

    func testLateFourthFingerDoesNotConvertDragToPaste() {
        frame(0, chord(3))
        frame(0.12, chord(3, phase: .stationary) + [touch(4)])
        XCTAssertNil(frame(0.20, []))
    }

    func testBriefFourthFingerDoesNotFallBackToCopy() {
        frame(0, chord(3))
        frame(0.05, chord(3, phase: .stationary) + [touch(4)])
        frame(0.06, chord(3, phase: .stationary))
        XCTAssertNil(frame(0.10, []))
    }

    func testAccidentalVeryShortChordDoesNotTrigger() {
        frame(0, chord(4))
        XCTAssertNil(frame(0.01, []))
    }

    func testCancelledContactInvalidatesWholeSequence() {
        frame(0, chord(3))
        frame(0.05, [touch(1, .cancelled)] + Array(chord(3, phase: .stationary).dropFirst()))
        XCTAssertNil(frame(0.10, []))
    }

    func testRepeatedTapsCanTriggerWithoutMovingPointer() {
        for start in [0.0, 0.2, 0.4] {
            frame(start, chord(3))
            XCTAssertEqual(frame(start + 0.10, [])?.fingerCount, 3)
        }
    }

    func testDevicesHaveIndependentStateEvenWithSameFingerIdentities() {
        frame(0, chord(3))
        frame(0.01, chord(4), device: "magic-trackpad")
        XCTAssertEqual(frame(0.10, []), TrackpadTap(deviceID: "built-in", fingerCount: 3))
        XCTAssertEqual(frame(0.11, [], device: "magic-trackpad"), TrackpadTap(deviceID: "magic-trackpad", fingerCount: 4))
    }

    func testRestingThumbIsIgnoredAndDoesNotPreventRelease() {
        let thumb = touch(99, .stationary, resting: true)
        frame(0, [thumb])
        frame(0.01, chord(3) + [thumb])
        XCTAssertEqual(frame(0.11, [thumb])?.fingerCount, 3)
    }

    func testParticipatingFingerBecomingRestingCancelsTap() {
        frame(0, chord(3))
        frame(0.05, [touch(1, .stationary, resting: true)] + Array(chord(3, phase: .stationary).dropFirst()))
        XCTAssertNil(frame(0.10, []))
    }

    func testAttachingListenerMidGestureCannotEmitTap() {
        frame(0, chord(3, phase: .moved))
        XCTAssertNil(frame(0.10, []))
    }

    func testReplacingFingerWithinSequenceRejectsTap() {
        frame(0, chord(3))
        frame(0.04, [touch(1, .stationary, x: 0.15), touch(2, .stationary, x: 0.30), touch(4)])
        XCTAssertNil(frame(0.10, []))
    }

    func testDuplicateContactIdentityRejectsFrame() {
        frame(0, [touch(1), touch(1), touch(2), touch(3)])
        XCTAssertNil(frame(0.10, []))
    }

    func testInvalidPositionDoesNotTrigger() {
        for x in [CGFloat.nan, CGFloat.infinity, -0.1, 1.1] {
            frame(0, [touch(1, x: x), touch(2), touch(3)])
            XCTAssertNil(frame(0.10, []))
        }
    }

    func testInvalidOrBackwardTimestampDoesNotTrigger() {
        frame(0.1, chord(3))
        XCTAssertNil(frame(0.05, []))
        frame(.nan, chord(3))
        XCTAssertNil(frame(0.10, []))
    }

    func testClickOrScrollCancellationPersistsUntilRelease() {
        frame(0, chord(3))
        recognizer.cancelCandidates()
        frame(0.05, chord(3, phase: .stationary))
        XCTAssertNil(frame(0.10, []))
        frame(0.20, chord(3))
        XCTAssertEqual(frame(0.30, [])?.fingerCount, 3)
    }

    func testDeviceDisconnectOnlyResetsThatDevice() {
        frame(0, chord(3))
        frame(0.01, chord(4), device: "magic-trackpad")
        recognizer.reset(deviceID: "magic-trackpad")
        XCTAssertNil(frame(0.10, [], device: "magic-trackpad"))
        XCTAssertEqual(frame(0.11, [])?.fingerCount, 3)
    }

    func testSleepResetDropsAllPendingTaps() {
        frame(0, chord(3))
        frame(0.01, chord(4), device: "magic-trackpad")
        recognizer.reset()
        XCTAssertNil(frame(0.10, []))
        XCTAssertNil(frame(0.11, [], device: "magic-trackpad"))
    }

    func testFingerThatLiftsAndReturnsCannotBecomeFreshTap() {
        frame(0, chord(3))
        frame(0.04, Array(chord(3, phase: .stationary).dropFirst()))
        frame(0.06, [touch(1)] + Array(chord(3, phase: .stationary).dropFirst()))
        XCTAssertNil(frame(0.12, []))
    }

    func testSeparateDevicesCannotCombineIntoThreeFingerTap() {
        frame(0, chord(2))
        frame(0.01, chord(1), device: "magic-trackpad")
        XCTAssertNil(frame(0.10, []))
        XCTAssertNil(frame(0.11, [], device: "magic-trackpad"))
    }

    func testCustomConfigurationCanCalibrateDurationAndMovement() {
        var configuration = TrackpadTapRecognizer.Configuration()
        configuration.maximumDuration = 0.5
        configuration.maximumMovement = 0.1
        recognizer = TrackpadTapRecognizer(configuration: configuration)
        frame(0, chord(3))
        frame(0.05, [touch(1, .moved, x: 0.20)] + Array(chord(3, phase: .stationary).dropFirst()))
        XCTAssertEqual(frame(0.4, [])?.fingerCount, 3)
    }
}
