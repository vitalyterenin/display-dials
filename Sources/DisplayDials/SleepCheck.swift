import AppKit
import Darwin

/// Diagnostic-only, real sleep/wake check. It never initiates system sleep itself.
/// The ordinary app does not resume Boost automatically after waking.
@MainActor
final class SleepCheck: NSObject {
    private let boost = BoostController()
    private var stage = "starting"
    private var sawWake = false
    private var stopReason: String?
    static var resultURL: URL {
        BoostTrace.url.deletingLastPathComponent().appendingPathComponent("sleep-check.json")
    }

    func run() {
        NSApp.setActivationPolicy(.prohibited)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        boost.onChange = { [weak self] in self?.changed() }
        save()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 900) { _exit(76) }
        boost.start()
    }

    private func changed() {
        if stage == "starting", boost.report.phase == "active", boost.report.factor >= 1.09 {
            stage = "readyForSleep"; save()
            print("Ready for actual system sleep. Wake the Mac normally afterwards.")
        } else if stage == "readyForSleep", !boost.running {
            stopReason = boost.report.reason
            guard ["sleeping", "sessionInactive", "heartbeat"].contains(stopReason ?? "") else {
                fail("Unexpected stop before sleep/wake: \(stopReason ?? "unknown")"); return
            }
            stage = "waitingForWake"; save(); verifyAfterWake()
        } else if stage == "restarting", boost.report.phase == "active", boost.report.factor >= 1.05 {
            stage = "stoppingRestart"; boost.stop()
        } else if stage == "stoppingRestart", !boost.running {
            stage = "passed"; save()
            print("PASS: real wake observed, Boost stayed off, explicit restart succeeded.")
            exit(0)
        }
    }

    @objc private func didWake() {
        sawWake = true; save(); verifyAfterWake()
    }

    private func verifyAfterWake() {
        guard sawWake, stage == "waitingForWake" else { return }
        stage = "checkingNoAutoResume"; save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            guard !self.boost.running, self.boost.report.phase == "off" else {
                self.fail("Boost resumed automatically"); return
            }
            self.stage = "waitingForUnlock"; self.save()
            self.restartWhenUnlocked(attempt: 0)
        }
    }

    private func restartWhenUnlocked(attempt: Int) {
        guard stage == "waitingForUnlock" else { return }
        guard attempt < 120 else { fail("Session stayed locked after wake"); return }
        guard BoostPlatform.sessionActive else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.restartWhenUnlocked(attempt: attempt + 1)
            }
            return
        }
        stage = "restarting"; save()
        // An explicit diagnostic start action, not product auto-resume behavior.
        boost.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.fail("Explicit restart did not complete")
        }
    }

    private func fail(_ message: String) {
        stage = "failed"; save(error: message); boost.stop(); exit(1)
    }

    private func save(error: String? = nil) {
        var result: [String: Any] = ["stage": stage, "sawSystemWake": sawWake,
            "workerRunning": boost.running, "phase": boost.report.phase,
            "factor": boost.report.factor]
        if let stopReason { result["stopReason"] = stopReason }
        if let error { result["error"] = error }
        do {
            try FileManager.default.createDirectory(at: Self.resultURL.deletingLastPathComponent(),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.resultURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.resultURL.path)
        } catch { /* Diagnostic file failure does not change the safety behavior. */ }
    }
}
