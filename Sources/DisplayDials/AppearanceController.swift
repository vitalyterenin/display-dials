import Foundation

@MainActor
final class AppearanceController {
    struct ChangeError: LocalizedError, Sendable {
        let detail: String
        var errorDescription: String? { detail }
    }

    private let change: @Sendable () async throws -> Bool
    private(set) var isChanging = false
    private(set) var lastError: String?

    init(change: @escaping @Sendable () async throws -> Bool = AppearanceController.changeSystemAppearance) {
        self.change = change
    }

    /// Ignore overlapping requests while macOS is applying the change or asking for permission.
    func toggle() async throws {
        guard !isChanging else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            _ = try await change()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    nonisolated static func changeSystemAppearance() async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            let script = """
                with timeout of 15 seconds
                    tell application "System Events"
                        tell appearance preferences
                            set requestedMode to not dark mode
                            set dark mode to requestedMode
                            if dark mode is not requestedMode then error "macOS did not apply the appearance change."
                            return dark mode
                        end tell
                    end tell
                end timeout
                """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            // Drain one pipe before waiting; never block the app's main run loop.
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0, result == "true" || result == "false" else {
                if result.contains("-1743") || result.contains("-1744") {
                    throw ChangeError(detail: "Allow Display Dials to control System Events in System Settings → Privacy & Security → Automation, then try again.")
                }
                throw ChangeError(detail: result.isEmpty ? "macOS could not change the appearance. Try again." : result)
            }
            return result == "true"
        }.value
    }
}
