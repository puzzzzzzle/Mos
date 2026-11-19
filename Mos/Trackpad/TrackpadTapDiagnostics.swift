import Foundation
import os.log

/// Debug-only, bounded diagnostics. Never log clipboard data or key contents.
/// Disk writes run on a utility queue, outside the touch/event callback path.
final class TrackpadTapDiagnostics {
    #if DEBUG
    private struct Counters {
        var frames = 0
        var activeFrames = 0
        var idleFrames = 0
        var maximumFingers = 0
        var lastTimestamp: TimeInterval = 0
    }

    private var devices: [UInt: Counters] = [:]
    private var cancellations: [String: Int] = [:]
    private let queue = DispatchQueue(label: "com.caldis.Mos.trackpadDiagnostics", qos: .utility)
    private let log = OSLog(subsystem: "com.caldis.Mos", category: "TrackpadTap")
    private var lastSummary: TimeInterval = 0

    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Mos/trackpad-taps.log")
    #endif

    func write(_ message: @autoclosure () -> String) {
        #if DEBUG
        let line = message()
        os_log("%{public}@", log: log, type: .default, line)
        queue.async { [log] in
            let url = Self.fileURL
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true, attributes: nil)
                if manager.fileExists(atPath: url.path) {
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    if (attributes[.size] as? NSNumber)?.intValue ?? 0 > 512 * 1024 {
                        let previous = url.deletingPathExtension().appendingPathExtension("previous.log")
                        if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                        try manager.moveItem(at: url, to: previous)
                    }
                }
                if !manager.fileExists(atPath: url.path) {
                    guard manager.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { return }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let output = "\(timestamp) pid=\(ProcessInfo.processInfo.processIdentifier) \(line)\n"
                if let data = output.data(using: .utf8) { handle.write(data) }
            } catch {
                os_log("Trackpad log write failed: %{public}@", log: log, type: .error, error.localizedDescription)
            }
        }
        #endif
    }

    func reset() {
        #if DEBUG
        devices.removeAll()
        cancellations.removeAll()
        lastSummary = ProcessInfo.processInfo.systemUptime
        #endif
    }

    func frame(device: UInt, contacts: [TrackpadContact], timestamp: TimeInterval, receivedAt: TimeInterval) {
        #if DEBUG
        var counter = devices[device] ?? Counters()
        if counter.frames == 0 {
            write("first-frame device=\(device) nativeTime=\(timestamp) hostTime=\(receivedAt) states=\(contacts.map { $0.state })")
        }
        let active = contacts.reduce(0) { $0 + (($1.state == 3 || $1.state == 4) ? 1 : 0) }
        counter.frames += 1
        counter.activeFrames += active > 0 ? 1 : 0
        counter.idleFrames += active == 0 ? 1 : 0
        counter.maximumFingers = max(counter.maximumFingers, active)
        counter.lastTimestamp = timestamp
        devices[device] = counter
        #endif
    }

    func cancel(event: String) {
        #if DEBUG
        cancellations[event, default: 0] += 1
        #endif
    }

    func summarize(force: Bool = false) {
        #if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSummary >= 5 else { return }
        lastSummary = now
        if devices.isEmpty { write("summary no-touch-frames") }
        for (device, counter) in devices {
            write("summary device=\(device) frames=\(counter.frames) active=\(counter.activeFrames) idle=\(counter.idleFrames) peakFingers=\(counter.maximumFingers) nativeTime=\(counter.lastTimestamp)")
        }
        if !cancellations.isEmpty {
            write("cancellations \(cancellations)")
            cancellations.removeAll()
        }
        #endif
    }
}
