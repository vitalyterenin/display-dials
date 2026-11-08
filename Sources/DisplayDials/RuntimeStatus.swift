import Foundation

/// Read-only diagnostics from the running app's own permission/launch context.
@MainActor
final class RuntimeStatus {
    private static let request = Notification.Name("com.vitalyterenin.displaydials.status.request")
    private static let reply = Notification.Name("com.vitalyterenin.displaydials.status.reply")
    private var observer: NSObjectProtocol?

    func start(snapshot: @escaping @MainActor () -> [String: Any]) {
        observer = DistributedNotificationCenter.default().addObserver(forName: Self.request,
            object: nil, queue: .main) { notification in
                guard let nonce = notification.object as? String else { return }
                MainActor.assumeIsolated {
                    DistributedNotificationCenter.default().postNotificationName(Self.reply,
                        object: nonce, userInfo: snapshot(), deliverImmediately: true)
                }
            }
    }

    @MainActor private final class Response { var data: Data? }

    static func query() -> Bool {
        let nonce = UUID().uuidString
        let response = Response()
        let center = DistributedNotificationCenter.default()
        let token = center.addObserver(forName: reply, object: nonce, queue: .main) { notification in
            guard let info = notification.userInfo,
                  let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) else { return }
            MainActor.assumeIsolated { response.data = data }
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(request, object: nonce, userInfo: nil, deliverImmediately: true)
        let deadline = Date(timeIntervalSinceNow: 2)
        while response.data == nil && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        guard let json = response.data, let text = String(data: json, encoding: .utf8) else {
            print("No response from a running Display Dials app.")
            return false
        }
        print(text)
        return true
    }
}
