import Foundation
import Observation
import os.log

@Observable
class ActivityLog {
    static let shared = ActivityLog()

    var entries: [LogEntry] = []

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: Level

        enum Level: String {
            case info = "INFO"
            case success = "OK"
            case warning = "WARN"
            case error = "ERROR"
        }

        var timeString: String {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss.SSS"
            return fmt.string(from: timestamp)
        }
    }

    private static let osLog = OSLog(subsystem: "uk.ac.ucl.eof", category: "app")

    func log(_ message: String, level: LogEntry.Level = .info) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        let logType: OSLogType = level == .error ? .error : level == .warning ? .fault : .default
        os_log("%{public}@ %{public}@", log: Self.osLog, type: logType, level.rawValue, message)
        if Thread.isMainThread {
            entries.append(entry)
        } else {
            DispatchQueue.main.async { [self] in
                entries.append(entry)
            }
        }
    }

    func info(_ message: String) { log(message, level: .info) }
    func success(_ message: String) { log(message, level: .success) }
    func warn(_ message: String) { log(message, level: .warning) }
    func error(_ message: String) { log(message, level: .error) }

    func clear() { entries.removeAll() }
}
