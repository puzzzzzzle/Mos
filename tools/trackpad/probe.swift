import Cocoa
import IOKit

private func message(_ english: String, _ chinese: String) -> String {
    let chineseLocale = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    return NSLocalizedString(english, tableName: nil, bundle: .main,
                             value: chineseLocale ? chinese : english,
                             comment: "Standalone trackpad diagnostic")
}

private enum Source: String {
    case `public`, `private`
}

private final class TrackpadProbe {
    static var current: TrackpadProbe?
    private var recognizer = TrackpadTapRecognizer()
    private var privateInput = TrackpadTapInput()
    private let source: Source
    private let execute: Bool
    private var monitors: [Any] = []
    private var notifications: [NSObjectProtocol] = []
    private var deviceTimer: Timer?
    private var running = false
    private var generation: UInt64 = 0
    private var activeDevices = Set<AnyHashable>()
    private var nextDeviceLabel = 1
    private var deviceLabels: [AnyHashable: Int] = [:]
    private var frameCount = 0
    private var tapCount = 0
    private var emptyGestureCount = 0

    init(source: Source, execute: Bool) { self.source = source; self.execute = execute }

    func start() -> Bool {
        Self.current = self
        let cancellationMask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .scrollWheel, .swipe,
            .magnify, .rotate, .pressure
        ]
        let mask = source == .public ? cancellationMask.union(.gesture) : cancellationMask
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.receive(event)
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.receive(event)
            return event
        }) { monitors.append(monitor) }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.suspend()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.resume()
            })
        }
        running = true
        if source == .private {
            guard startPrivateListener() else { stop(); return false }
            // Poll only topology, not reports. Rebuild listeners after reconnection.
            deviceTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.checkDeviceTopology()
            }
            RunLoop.main.add(deviceTimer!, forMode: .common)
        }
        return true
    }

    func stop() {
        suspend()
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        notifications.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        notifications.removeAll()
        deviceTimer?.invalidate()
        deviceTimer = nil
        Self.current = nil
        print(message("Stopped. Frames: %d; recognized taps: %d.", "已停止。触摸帧：%d；识别轻点：%d。")
            .formattedForProbe(frameCount, tapCount))
        if source == .public {
            print(message("Gesture events without contacts: %d.", "未包含触摸点的手势事件：%d。")
                .formattedForProbe(emptyGestureCount))
        }
    }

    private func suspend() {
        running = false
        generation += 1
        privateInput.stop()
        if source == .private { MosTrackpadStop() }
        recognizer.reset()
    }

    private func resume() {
        guard !running else { return }
        running = true
        if source == .private && !startPrivateListener() { running = false }
    }

    private func receive(_ event: NSEvent) {
        guard running else { return }
        guard source == .public && event.type == .gesture else {
            recognizer.cancelCandidates()
            privateInput.cancel()
            return
        }
        let touches = event.allTouches().filter { $0.type == .indirect }
        if touches.isEmpty { emptyGestureCount += 1 }
        var groups: [AnyHashable: [TrackpadTouch]] = [:]
        for touch in touches {
            guard let device = touch.device as? NSObject, let identity = touch.identity as? NSObject else { continue }
            let phase: TrackpadTouch.Phase
            switch touch.phase {
            case .began: phase = .began
            case .moved: phase = .moved
            case .stationary: phase = .stationary
            case .ended: phase = .ended
            case .cancelled: phase = .cancelled
            default: continue
            }
            groups[AnyHashable(device), default: []].append(TrackpadTouch(
                identity: AnyHashable(identity), position: touch.normalizedPosition,
                phase: phase, isResting: touch.isResting))
        }
        // Empty generic events do not reliably identify which device ended.
        // Wait for per-contact ended/cancelled events rather than guessing.
        for (device, contacts) in groups {
            process(TrackpadTouchFrame(deviceID: device, timestamp: event.timestamp, touches: contacts))
        }
    }

    private func process(_ frame: TrackpadTouchFrame) {
        frameCount += 1
        if deviceLabels[frame.deviceID] == nil {
            deviceLabels[frame.deviceID] = nextDeviceLabel
            nextDeviceLabel += 1
            print(message("Receiving touch data from device %d.", "正在接收设备 %d 的触摸数据。")
                .formattedForProbe(deviceLabels[frame.deviceID]!))
        }
        if let tap = recognizer.process(frame) {
            record(tap)
        }
    }

    private func record(_ tap: TrackpadTap) {
        tapCount += 1
        let action = tap.fingerCount == 3 ? message("Copy", "复制") : message("Paste", "粘贴")
        print(message("Device %d: %d-finger tap → %@", "设备 %d：%d 指轻点 → %@")
            .formattedForProbe(deviceLabels[tap.deviceID]!, tap.fingerCount, action))
        guard execute else { return }
        guard AXIsProcessTrusted() else {
            print(message("Accessibility access is unavailable; action skipped.", "没有辅助功能权限，已跳过动作。"))
            return
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty else { return }
        for event in TrackpadShortcutEvents.make(code: tap.fingerCount == 3 ? 8 : 9, marker: 0x4D6F73) {
            event.post(tap: .cghidEventTap)
        }
        print(message("Shortcut posted.", "已发送快捷键。"))
    }

    private func startPrivateListener() -> Bool {
        generation = privateInput.start(notBefore: ProcessInfo.processInfo.systemUptime)
        recognizer.reset()
        activeDevices = deviceTopology()
        guard MosTrackpadStart({ device, contacts, count, timestamp, receivedAt, generation in
            let snapshot = count == 0 ? [] : Array(UnsafeBufferPointer(start: contacts, count: Int(count)))
            // Frame data is framework-owned; copy it before returning from callback.
            // Serialize recognition and UI output on the main queue.
            DispatchQueue.main.async {
                TrackpadProbe.current?.receivePrivate(device: device, contacts: snapshot,
                    timestamp: timestamp, receivedAt: receivedAt, generation: generation)
            }
        }, generation) else {
            fputs(String(cString: MosTrackpadError()) + "\n", stderr)
            return false
        }
        print(message("Listening to %d supported trackpads.", "正在监听 %d 个支持的触控板。")
            .formattedForProbe(Int(MosTrackpadDeviceCount())))
        return true
    }

    private func receivePrivate(device: UInt, contacts: [MosTrackpadContact], timestamp: TimeInterval,
                                receivedAt: TimeInterval, generation: UInt64) {
        guard running, generation == self.generation else { return }
        frameCount += 1
        if deviceLabels[AnyHashable(device)] == nil {
            deviceLabels[AnyHashable(device)] = nextDeviceLabel
            nextDeviceLabel += 1
            print(message("Receiving touch data from device %d.", "正在接收设备 %d 的触摸数据。")
                .formattedForProbe(deviceLabels[AnyHashable(device)]!))
        }
        let snapshot = contacts.map { TrackpadContact(identity: $0.identity, state: $0.state,
            position: CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))) }
        if let action = privateInput.process(device: device, contacts: snapshot,
                                              timestamp: timestamp, receivedAt: receivedAt,
                                              generation: generation) {
            record(TrackpadTap(deviceID: device, fingerCount: action == .copy ? 3 : 4))
        }
    }

    private func deviceTopology() -> Set<AnyHashable> {
        var iterator: io_iterator_t = 0
        let mainPort: mach_port_t
        if #available(macOS 12.0, *) { mainPort = kIOMainPortDefault }
        else { mainPort = kIOMasterPortDefault }
        guard IOServiceGetMatchingServices(mainPort,
            IOServiceMatching("AppleMultitouchDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = Set<AnyHashable>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            var identifier: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS {
                result.insert(identifier)
            }
            IOObjectRelease(service)
        }
        return result
    }

    private func checkDeviceTopology() {
        guard running, deviceTopology() != activeDevices else { return }
        privateInput.stop()
        MosTrackpadStop()
        if !startPrivateListener() { running = false }
    }
}

private extension String {
    func formattedForProbe(_ arguments: CVarArg...) -> String {
        String(format: self, arguments: arguments)
    }
}

@main
private struct ProbeMain {
    static func main() {
        setbuf(stdout, nil)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty, !arguments.contains("--help") else {
            print(message("Usage: probe --listen [--source public|private] [--duration seconds] [--execute]",
                          "用法：probe --listen [--source public|private] [--duration 秒数] [--execute]"))
            return
        }
        var source = Source.public
        var duration: TimeInterval = 60
        var listen = false
        var execute = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--listen": listen = true
            case "--execute": execute = true
            case "--source":
                index += 1
                guard index < arguments.count, let value = Source(rawValue: arguments[index]) else { failArguments() }
                source = value
            case "--duration":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      value.isFinite, (1...600).contains(value) else { failArguments() }
                duration = value
            default: failArguments()
            }
            index += 1
        }
        guard listen else { failArguments() }
        guard !execute || (source == .private && AXIsProcessTrusted()) else {
            fputs(message("Execution requires --source private and Accessibility access. No listener started.\n",
                          "实际执行需要 --source private 和辅助功能权限，尚未启动监听。\n"), stderr)
            exit(3)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let probe = TrackpadProbe(source: source, execute: execute)
        guard probe.start() else { exit(1) }
        if execute {
            print(message("Three-finger tap posts Copy; four-finger tap posts Paste to the front app. Ctrl-C to stop.",
                          "三指轻点将向前台应用发送复制，四指轻点发送粘贴。按 Ctrl-C 停止。"))
        } else {
            print(message("Tap with three or four fingers. Recognition only. Ctrl-C to stop.",
                          "请用三指或四指轻点。当前仅识别，按 Ctrl-C 停止。"))
        }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { value -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { probe.stop(); exit(0) }
            source.resume()
            return source
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { probe.stop(); exit(0) }
        withExtendedLifetime(signals) { NSApp.run() }
    }

    private static func failArguments() -> Never {
        fputs(message("Invalid arguments. Use --help. Duration must be between 1 and 600 seconds.\n",
                      "参数无效，请使用 --help。时长须为 1 至 600 秒。\n"), stderr)
        exit(2)
    }
}
