import Cocoa
import IOKit

/// Opt-in, session-only experiment. Initialization never opens a device.
final class TrackpadTapManager {
    static let shared = TrackpadTapManager()
    static let enabledDidChangeNotification = Notification.Name("MosTrackpadTapEnabledDidChange")
    // The C callback routes to this main-thread reference. The generation is
    // captured on the callback thread and checked before executing any action.
    private static weak var listener: TrackpadTapManager?

    private(set) var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            NotificationCenter.default.post(name: Self.enabledDidChangeNotification, object: self)
        }
    }
    private var input = TrackpadTapInput()
    private var monitors: [Any] = []
    private var deviceTimer: Timer?
    private var topology = Set<UInt64>()
    private let diagnostics = TrackpadTapDiagnostics()

    private init() {}

    /// Returns false without changing permissions if this system cannot listen.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        precondition(Thread.isMainThread)
        if !enabled {
            diagnostics.write("switch off")
            isEnabled = false
            suspend()
            return true
        }
        guard AXIsProcessTrusted() else {
            diagnostics.write("switch on denied: accessibility=false")
            return false
        }
        diagnostics.write("switch on accessibility=true")
        isEnabled = true
        guard resume() else {
            isEnabled = false
            return false
        }
        return true
    }

    @discardableResult
    func resume() -> Bool {
        precondition(Thread.isMainThread)
        guard isEnabled else { return true }
        guard AXIsProcessTrusted() else { return false }
        guard !input.isActive else { return true }
        diagnostics.reset()
        Self.listener = self
        let generation = input.start(notBefore: ProcessInfo.processInfo.systemUptime)
        installCancellationMonitors()
        guard MosTrackpadStart({ device, contacts, count, timestamp, receivedAt, generation in
            let snapshot: [TrackpadContact] = count == 0 ? [] :
                UnsafeBufferPointer(start: contacts, count: Int(count)).map {
                    TrackpadContact(identity: $0.identity, state: $0.state,
                                    position: CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
                }
            DispatchQueue.main.async {
                TrackpadTapManager.listener?.receive(device: device, contacts: snapshot,
                                                     timestamp: timestamp, receivedAt: receivedAt,
                                                     generation: generation)
            }
        }, generation) else {
            diagnostics.write("listener failed: \(String(cString: MosTrackpadError()))")
            suspend()
            isEnabled = false
            return false
        }
        topology = Self.deviceTopology()
        diagnostics.write("listener started devices=\(MosTrackpadDeviceCount()) generation=\(generation)")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkDevicesAndPermissions()
        }
        deviceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func suspend() {
        precondition(Thread.isMainThread)
        let wasActive = input.isActive
        if wasActive {
            diagnostics.summarize(force: true)
            diagnostics.write("listener stopped generation=\(input.generation)")
        }
        input.stop()
        Self.listener = nil
        // With the switch off, do not even load the private framework.
        if wasActive { MosTrackpadStop() }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        deviceTimer?.invalidate()
        deviceTimer = nil
        topology.removeAll()
    }

    private func installCancellationMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .swipe, .magnify, .rotate, .pressure
        ]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.diagnostics.cancel(event: String(describing: event.type))
            self?.input.cancel()
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.diagnostics.cancel(event: String(describing: event.type))
            self?.input.cancel()
            return event
        }) { monitors.append(monitor) }
    }

    private func receive(device: UInt, contacts: [TrackpadContact],
                         timestamp: TimeInterval, receivedAt: TimeInterval, generation: UInt64) {
        guard input.isActive, generation == input.generation else { return }
        diagnostics.frame(device: device, contacts: contacts, timestamp: timestamp, receivedAt: receivedAt)
        guard let action = input.process(device: device, contacts: contacts,
                                         timestamp: timestamp, receivedAt: receivedAt,
                                         generation: generation) else { return }
        diagnostics.write("recognized device=\(device) action=\(action)")
        guard AXIsProcessTrusted() else {
            diagnostics.write("action skipped: accessibility=false")
            suspend()
            return
        }
        // Respect active menus and physical modifier keys; never turn a gesture
        // during keyboard use into an unintended Command-Option/Shift shortcut.
        let physicalFlags = CGEventSource.flagsState(.hidSystemState)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard RunLoop.current.currentMode != .eventTracking else {
            diagnostics.write("action skipped: menu tracking")
            return
        }
        guard physicalFlags.intersection(modifiers).isEmpty else {
            diagnostics.write("action skipped: physical modifier held")
            return
        }
        let posted = ShortcutExecutor.shared.execute(trackpadAction: action)
        diagnostics.write("action=\(action) keyboardPairPosted=\(posted)")
    }

    private func checkDevicesAndPermissions() {
        diagnostics.summarize()
        guard AXIsProcessTrusted() else { suspend(); return }
        guard Self.deviceTopology() != topology else { return }
        diagnostics.write("device topology changed; rebuilding listener")
        suspend()
        // If no supported devices remain, disable rather than silently claiming
        // to listen. The user can enable the preference after reconnecting.
        if !resume() { isEnabled = false }
    }

    private static func deviceTopology() -> Set<UInt64> {
        var iterator: io_iterator_t = 0
        let port: mach_port_t
        if #available(macOS 12.0, *) { port = kIOMainPortDefault }
        else { port = kIOMasterPortDefault }
        guard IOServiceGetMatchingServices(port, IOServiceMatching("AppleMultitouchDevice"),
                                          &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices = Set<UInt64>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            var identifier: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS {
                devices.insert(identifier)
            }
            IOObjectRelease(service)
        }
        return devices
    }
}
