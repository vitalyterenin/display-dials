import Foundation
import DisplayCore

/// A bounded, local trace of the latest trial. No screen content is collected.
@MainActor
final class BoostTrace {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DisplayDials/latest-boost.jsonl")
    }
    private var file: FileHandle?
    private var bytesWritten = 0

    func begin() {
        try? file?.close(); file = nil; bytesWritten = 0
        do {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data().write(to: Self.url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
            file = try FileHandle(forWritingTo: Self.url)
            record("start")
        } catch { file = nil }
    }

    func record(_ event: String, report: BoostReport? = nil, status: Int32? = nil) {
        struct Entry: Encodable {
            var event: String
            var uptime: Double
            var report: BoostReport?
            var exitStatus: Int32?
        }
        guard let file else { return }
        if bytesWritten >= 1_000_000 {
            do {
                try file.truncate(atOffset: 0)
                try file.seek(toOffset: 0)
                bytesWritten = 0
            } catch { return }
        }
        guard var bytes = try? JSONEncoder().encode(Entry(event: event,
                uptime: ProcessInfo.processInfo.systemUptime, report: report, exitStatus: status)) else { return }
        bytes.append(10)
        try? file.write(contentsOf: bytes)
        bytesWritten += bytes.count
    }
}
