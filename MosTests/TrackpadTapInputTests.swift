import XCTest
import Cocoa
@testable import Mos_Debug

final class TrackpadTapInputTests: XCTestCase {
    private var input = TrackpadTapInput()

    private func chord(_ fingers: Int = 3, state: Int32 = 4) -> [TrackpadContact] {
        (1...fingers).map { TrackpadContact(identity: Int32($0), state: state,
            position: CGPoint(x: Double($0) * 0.15, y: 0.5)) }
    }

    @discardableResult
    private func frame(_ timestamp: Double, _ contacts: [TrackpadContact],
                       device: UInt = 1, receivedAt: Double? = nil, generation: UInt64? = nil) -> TrackpadAction? {
        input.process(device: device, contacts: contacts, timestamp: timestamp,
                      receivedAt: receivedAt ?? timestamp,
                      generation: generation ?? input.generation)
    }

    func testDisabledInputCannotExecute() {
        frame(0, [])
        frame(0.1, chord())
        XCTAssertNil(frame(0.2, []))
    }

    func testThreeFingerTapCopiesAfterAllFingersRelease() {
        input.start()
        frame(0, [])
        XCTAssertNil(frame(0.1, chord()))
        frame(0.15, Array(chord(state: 5).prefix(1)) + Array(chord().dropFirst()))
        XCTAssertEqual(frame(0.2, []), .copy)
        XCTAssertNil(frame(0.21, []))
    }

    func testFourFingerTapPastesWithoutCopyFallback() {
        input.start()
        frame(0, [])
        frame(0.1, chord(4, state: 3))
        XCTAssertNil(frame(0.15, chord()))
        XCTAssertEqual(frame(0.2, []), .paste)
    }

    func testBothActiveStatesRequireIdleAfterStarting() {
        for state: Int32 in [3, 4] {
            input.start()
            frame(0, chord(state: state))
            XCTAssertNil(frame(0.1, []))
            frame(0.2, chord(state: state))
            XCTAssertEqual(frame(0.3, []), .copy)
        }
    }

    func testHoverAndLingeringContactsDoNotCountAsFingers() {
        input.start()
        frame(0, chord(state: 2))
        frame(0.1, chord() + [TrackpadContact(identity: 4, state: 2, position: .zero)])
        XCTAssertEqual(frame(0.2, chord(state: 7)), .copy)
        XCTAssertNil(frame(0.3, chord(state: 7)))
    }

    func testDevicesNeverShareArmingOrFingerCount() {
        input.start()
        frame(0, [], device: 1)
        frame(0.1, chord(), device: 2)
        frame(0.1, chord(2), device: 1)
        XCTAssertNil(frame(0.2, [], device: 2))
        XCTAssertNil(frame(0.2, [], device: 1))
    }

    func testStoppedInputDropsQueuedRelease() {
        let generation = input.start()
        frame(0, [])
        frame(0.1, chord())
        input.stop()
        XCTAssertNil(frame(0.2, [], generation: generation))
    }

    func testRestartRejectsPreviousGenerationAndMidGesture() {
        let old = input.start()
        frame(0, [])
        frame(0.1, chord())
        input.start()
        XCTAssertNil(frame(0.2, [], generation: old))
        frame(0.3, chord())
        XCTAssertNil(frame(0.4, []))
        frame(0.5, chord())
        XCTAssertEqual(frame(0.6, []), .copy)
    }

    func testLateOldCallbackArrivalCannotArmNewListenerEvenWithNewGeneration() {
        input.start(notBefore: 10)
        frame(100, [], receivedAt: 9)
        frame(10.1, chord())
        XCTAssertNil(frame(10.2, []))
        frame(10.3, chord())
        XCTAssertEqual(frame(10.4, []), .copy)
    }

    func testDeviceRelativeClockDoesNotCompareWithHostUptime() {
        input.start(notBefore: 1_596_000)
        frame(48, [], receivedAt: 1_596_001)
        frame(48.1, chord(), receivedAt: 1_596_001.1)
        XCTAssertEqual(frame(48.2, [], receivedAt: 1_596_001.2), .copy)
    }

    func testDevicesWithDifferentClockOriginsBothRecognize() {
        input.start(notBefore: 1_000)
        frame(10, [], device: 1, receivedAt: 1_001)
        frame(50_000, [], device: 2, receivedAt: 1_001)
        frame(10.1, chord(), device: 1, receivedAt: 1_002)
        frame(50_000.1, chord(4), device: 2, receivedAt: 1_002)
        XCTAssertEqual(frame(10.2, [], device: 1, receivedAt: 1_002.1), .copy)
        XCTAssertEqual(frame(50_000.2, [], device: 2, receivedAt: 1_002.1), .paste)
    }

    func testNonFiniteTimestampCannotArmListener() {
        input.start()
        frame(.nan, [])
        frame(0.1, chord())
        XCTAssertNil(frame(0.2, []))
    }

    func testInvalidTimestampCancelsActiveTap() {
        input.start()
        frame(0, [])
        frame(0.1, chord())
        frame(.nan, chord())
        XCTAssertNil(frame(0.2, []))
    }

    func testCancelRejectsRemainingFingersUntilIdle() {
        input.start()
        frame(0, [])
        frame(0.1, chord(4))
        input.cancel()
        frame(0.15, chord())
        XCTAssertNil(frame(0.2, []))
        frame(0.3, chord())
        XCTAssertEqual(frame(0.4, []), .copy)
    }

    func testCancelBeforeFirstFrameRequiresAnotherIdleSnapshot() {
        input.start()
        frame(0, [])
        input.cancel()
        frame(0.1, chord(state: 3))
        XCTAssertNil(frame(0.2, []))
    }

    func testUnknownContactStateCancelsInsteadOfReleasing() {
        input.start()
        frame(0, [])
        frame(0.1, chord())
        XCTAssertNil(frame(0.2, chord(state: 99)))
    }

    func testDuplicateIdentityRejectsFrame() {
        input.start()
        frame(0, [])
        frame(0.1, chord() + chord().prefix(1))
        XCTAssertNil(frame(0.2, []))
    }

    func testKeyboardPairsHaveCommandAndSyntheticMarkerWithoutRepeats() {
        for code: CGKeyCode in [8, 9] {
            let events = TrackpadShortcutEvents.make(code: code, marker: 0x4D6F73)
            XCTAssertEqual(events.map { $0.type }, [.keyDown, .keyUp])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [Int64(code), Int64(code)])
            XCTAssertEqual(events.map { $0.flags }, [.maskCommand, []])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.eventSourceUserData) }, [0x4D6F73, 0x4D6F73])
            XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventAutorepeat) }, [0, 0])
        }
        // Event construction only: tests never post keyboard events.
    }
}
