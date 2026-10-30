import AppKit
import DisplayCore
import Darwin

/// Disposable process: all overlay windows belong to it. EOF, missed heartbeats,
/// normal exit and SIGKILL all remove the process-owned effect without recovery writes.
@MainActor
final class BoostWorker: NSObject {
    private var session = BoostSession()
    private let watchdog = WorkerWatchdog()
    private var renderer: HDRRenderer?
    private var topology = ""
    private var targetID: CGDirectDisplayID = 0
    private var timer: Timer?
    private var input = Data()
    private var hasStarted = false
    private let launched = ProcessInfo.processInfo.systemUptime

    func run() {
        NSApp.setActivationPolicy(.prohibited)
        signal(SIGPIPE, SIG_IGN)
        watchdog.start()
        // These deadlines are diagnostic-only; ordinary Boost has no duration limit.
        if CommandLine.arguments.contains("--bounded-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(.timeout) }
        }
        if CommandLine.arguments.contains("--stall-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Thread.sleep(forTimeInterval: 10) }
        }
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in self?.receive(bytes) }
        }
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(check), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(check), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(suspend), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
    }

    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { finish(.heartbeat); return }
        guard input.count + bytes.count <= 8192 else { finish(.invalidInput); return }
        input.append(bytes)
        while let newline = input.firstIndex(of: 10) {
            let line = input.prefix(upTo: newline)
            input.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(BoostCommand.self, from: line) else { finish(.invalidInput); return }
            let now = ProcessInfo.processInfo.systemUptime
            if !hasStarted {
                hasStarted = true
                session.start(now: now, factor: message.factor)
                guard session.phase != .off else { finish(.invalidInput); return }
                guard BoostPlatform.sessionActive else { finish(.sessionInactive); return }
                guard BoostPlatform.thermal == .nominal else { finish(.thermal); return }
                guard BoostPlatform.conflictingApps.isEmpty else { finish(.conflict); return }
                guard let screen = BoostPlatform.screen, BoostPlatform.supported(screen) else { finish(.unsupported); return }
                targetID = BoostPlatform.displayID(screen)
                guard CGDisplayIsAsleep(targetID) == 0 else { finish(.sleeping); return }
                topology = BoostPlatform.topology
                do {
                    renderer = try HDRRenderer()
                    try renderer?.begin(on: screen, comparison: CommandLine.arguments.contains("--compare"),
                                        triggerOnly: CommandLine.arguments.contains("--trigger-only"))
                } catch { finish(.renderer); return }
            } else {
                session.receive(now: now, factor: message.factor)
            }
            tick()
        }
    }

    @objc private func suspend() { finish(.sleeping) }
    @objc private func check() { tick() }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard hasStarted else {
            if now - launched > 2 { finish(.heartbeat) }
            return
        }
        if renderer?.failed == true { finish(.renderer); return }
        let screen = NSScreen.screens.first { BoostPlatform.displayID($0) == targetID }
        var e = BoostSession.Environment()
        e.supported = screen.map(BoostPlatform.supported) ?? false
        e.awake = targetID != 0 && CGDisplayIsAsleep(targetID) == 0
        e.thermal = BoostPlatform.thermal
        e.headroom = screen.map { Double($0.maximumExtendedDynamicRangeColorComponentValue) } ?? 1
        e.rendererReady = renderer?.ready == true
        e.displayChanged = BoostPlatform.topology != topology
        e.sessionActive = BoostPlatform.sessionActive
        e.conflictingApp = !BoostPlatform.conflictingApps.isEmpty
        session.tick(now: now, environment: e)
        guard session.phase != .off else { finish(session.reason ?? .manual); return }
        do { try renderer?.render(factor: session.effective, now: now) }
        catch { finish(.renderer); return }
        var report = session.report(now: now)
        report.presentedFrames = renderer?.presentedFrames
        report.headroom = e.headroom
        report.brightnessReadback = BrightnessReadback.values(for: targetID)
        if CommandLine.arguments.contains("--trigger-only") { report.factor = 1 }
        watchdog.renew()
        emit(report)
    }

    private func emit(_ report: BoostReport) {
        guard var bytes = try? JSONEncoder().encode(report) else { _exit(70) }
        bytes.append(10)
        do { try FileHandle.standardOutput.write(contentsOf: bytes) }
        catch { renderer?.stop(); _exit(0) }
    }

    private func finish(_ reason: BoostSession.Stop) {
        session.stop(reason)
        renderer?.stop()
        emit(session.report(now: ProcessInfo.processInfo.systemUptime))
        _exit(0)
    }
}
