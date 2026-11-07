import CryptoKit
import Foundation

public enum UsageEvent: Sendable {
    case launched
    case collectionEnabled
    case panelOpened(PanelSource)
    case nightShiftChanged(enabled: Bool, succeeded: Bool)
    case warmthChanged(position: Int, succeeded: Bool)
    case updatePreferences(checks: Bool, installation: Bool)
    case manualUpdateCheck

    public enum PanelSource: String, Sendable { case launch, menuBar, reopen }

    var contents: (String, [String: String]) {
        switch self {
        case .launched: ("App.launched", [:])
        case .collectionEnabled: ("Statistics.enabled", [:])
        case .panelOpened(let source): ("Panel.opened", ["source": source.rawValue])
        case .nightShiftChanged(let enabled, let succeeded):
            ("NightShift.changed", ["enabled": String(enabled), "succeeded": String(succeeded)])
        case .warmthChanged(let position, let succeeded):
            ("Warmth.changed", ["position": String(min(10, max(1, position))), "succeeded": String(succeeded)])
        case .updatePreferences(let checks, let installation):
            ("Updates.preferences", ["automaticChecks": String(checks), "automaticInstallation": String(installation)])
        case .manualUpdateCheck: ("Updates.manualCheck", [:])
        }
    }
}

@MainActor
public protocol UsageTransport: AnyObject {
    func send(_ body: Data)
    func cancel()
}

/// A consent gate and a bounded, memory-only batch for the documented Ingest API v2.
@MainActor
public final class UsageTelemetry {
    static let consentKey = "usageStatisticsConsentV1"
    static let identifierKey = "usageStatisticsInstallationID"
    private let defaults: UserDefaults
    private let appID: String?
    private let version: String
    private let build: String
    private let runtimeAllowed: Bool
    private let testMode: Bool
    private let makeTransport: () -> any UsageTransport
    private var transport: (any UsageTransport)?
    private var pending: [Signal] = []
    private var timer: Timer?
    private var sessionID = UUID().uuidString
    private var started = false

    public var isConfigured: Bool { appID != nil && runtimeAllowed }
    public var hasChosen: Bool { defaults.object(forKey: Self.consentKey) != nil }
    public var isEnabled: Bool { isConfigured && defaults.bool(forKey: Self.consentKey) }

    public init(appID: String?, version: String, build: String,
                defaults: UserDefaults = .standard, runtimeAllowed: Bool = true,
                testMode: Bool = false, makeTransport: @escaping () -> any UsageTransport = { TelemetryDeckTransport() }) {
        self.appID = appID.flatMap { UUID(uuidString: $0)?.uuidString }
        self.version = version
        self.build = build
        self.defaults = defaults
        self.runtimeAllowed = runtimeAllowed
        self.testMode = testMode
        self.makeTransport = makeTransport
    }

    public func start() {
        guard !started, isConfigured else { return }
        started = true
        record(.launched)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isConfigured else { return }
        let previouslyEnabled = isEnabled
        defaults.set(enabled, forKey: Self.consentKey)
        if !enabled {
            // Do not emit an opt-out event. Forget unsent events and the local identity.
            timer?.invalidate()
            timer = nil
            pending.removeAll()
            transport?.cancel()
            transport = nil
            defaults.removeObject(forKey: Self.identifierKey)
            sessionID = UUID().uuidString
        } else if !previouslyEnabled {
            record(.collectionEnabled)
        }
    }

    public func record(_ event: UsageEvent) {
        guard started, isEnabled, let appID else { return }
        let identifier: String
        if let saved = defaults.string(forKey: Self.identifierKey) { identifier = saved }
        else {
            identifier = UUID().uuidString
            defaults.set(identifier, forKey: Self.identifierKey)
        }
        let hash = SHA256.hash(data: Data((appID + ":" + identifier).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let (type, parameters) = event.contents
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let common = [
            "TelemetryDeck.AppInfo.version": version,
            "TelemetryDeck.AppInfo.buildNumber": build,
            "TelemetryDeck.Device.platform": "macOS",
            "TelemetryDeck.Device.systemMajorMinorVersion": "\(os.majorVersion).\(os.minorVersion)"
        ]
        // No hardware IDs, locale, time zone, screen geometry, or free-form error text.
        let signal = Signal(appID: appID, clientUser: hash, sessionID: sessionID,
                            type: type, isTestMode: testMode,
                            receivedAt: ISO8601DateFormatter().string(from: Date()),
                            payload: common.merging(parameters) { _, value in value })
        if pending.count == 50 { pending.removeFirst() }
        pending.append(signal)
        guard timer == nil else { return }
        let scheduled = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        scheduled.tolerance = 10
        timer = scheduled
    }

    public func flush() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        guard let body = try? JSONEncoder().encode(batch) else { return }
        if transport == nil { transport = makeTransport() }
        transport?.send(body)
    }

    private struct Signal: Encodable {
        let appID: String
        let clientUser: String
        let sessionID: String
        let type: String
        let isTestMode: Bool
        let receivedAt: String
        let payload: [String: String]
    }
}

@MainActor
public final class TelemetryDeckTransport: UsageTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "DisplayDials-Telemetry/1"]
        session = URLSession(configuration: configuration)
    }

    public func send(_ body: Data) {
        var request = URLRequest(url: URL(string: "https://nom.telemetrydeck.com/v2/namespace/in.teren/")!)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        // Best effort: never retry or persist usage data when offline or over quota.
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    public func cancel() { session.invalidateAndCancel() }
}
