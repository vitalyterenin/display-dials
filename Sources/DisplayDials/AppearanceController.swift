import AppKit

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

    static func changeSystemAppearance() async throws -> Bool {
        // System Events can quit itself when idle. Launch it only on an explicit action.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            _ = try await NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: "/System/Library/CoreServices/System Events.app"),
                configuration: configuration)
        }
        // Descriptors stay inside this worker; synchronous Apple event replies never block AppKit.
        return try await Task.detached(priority: .userInitiated) {
            try SystemAppearanceClient().toggle()
        }.value
    }
}
