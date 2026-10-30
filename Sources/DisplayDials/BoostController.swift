import AppKit
import DisplayCore
import Darwin

@MainActor
final class BoostController {
    var onChange: (() -> Void)?
    private(set) var report = BoostReport(phase: "off")
    private(set) var factor: Double = 1.1
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var heartbeat: Timer?
    private var lastReport = 0.0
    private var generation = UUID()
    private var stopping = false
    private let triggerOnly: Bool
    private let trace = BoostTrace()

    init(triggerOnly: Bool = false) { self.triggerOnly = triggerOnly }

    var running: Bool { process != nil }

    var unavailableReason: String? {
        if !BoostPlatform.conflictingApps.isEmpty { return BoostPlatform.reason("conflict") }
        guard let screen = BoostPlatform.screen, BoostPlatform.supported(screen) else { return BoostPlatform.reason("unsupported") }
        if BoostPlatform.thermal != .nominal { return BoostPlatform.reason("thermal") }
        if !BoostPlatform.sessionActive { return BoostPlatform.reason("sessionInactive") }
        return nil
    }

    func start() {
        guard !running else { return }
        if unavailableReason != nil { onChange?(); return }
        if factor <= 1 { factor = 1.1 }
        trace.begin()
        signal(SIGPIPE, SIG_IGN)
        let child = Process()
        let writer = Pipe(), reader = Pipe()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--boost-worker"] + (triggerOnly ? ["--trigger-only"] : [])
        child.standardInput = writer
        child.standardOutput = reader
        child.standardError = FileHandle.nullDevice
        let token = UUID(); generation = token
        reader.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == token, self.process != nil else { return }
                self.receive(bytes)
            }
        }
        child.terminationHandler = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.complete(status: status)
            }
        }
        do { try child.run() }
        catch {
            reader.fileHandleForReading.readabilityHandler = nil
            trace.record("launchFailed")
            report = BoostReport(phase: "off", reason: "renderer"); onChange?(); return
        }
        try? writer.fileHandleForReading.close()
        try? reader.fileHandleForWriting.close()
        process = child; input = writer.fileHandleForWriting; output = reader.fileHandleForReading
        stopping = false
        buffer = Data(); lastReport = ProcessInfo.processInfo.systemUptime
        report = BoostReport(phase: "preparing", remaining: Int(BoostSession.duration))
        sendHeartbeat()
        heartbeat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendHeartbeat() }
        }
        RunLoop.main.add(heartbeat!, forMode: .common)
        onChange?()
    }

    func changeFactor(_ value: Double) {
        guard value.isFinite else { stop(reason: "invalidInput"); return }
        factor = min(1.25, max(1, value))
        if factor <= 1 { stop(); return }
        if running { sendHeartbeat() }
        onChange?()
    }

    func stop(reason: String = "manual") {
        // EOF alone stops the worker; SIGTERM also closes its windows immediately.
        heartbeat?.invalidate(); heartbeat = nil
        stopping = true
        try? input?.close(); input = nil
        report = BoostReport(phase: "off", reason: reason)
        trace.record("stopRequested", report: report)
        if process?.isRunning == true { process?.terminate() }
        onChange?()
    }

    private func sendHeartbeat() {
        guard !stopping, process?.isRunning == true else { return }
        if ProcessInfo.processInfo.systemUptime - lastReport > 2.5 { stop(reason: "workerUnresponsive"); return }
        guard var data = try? JSONEncoder().encode(BoostCommand(factor: factor)) else { stop(reason: "invalidInput"); return }
        data.append(10)
        do { try input?.write(contentsOf: data) }
        catch { stop(reason: "heartbeat") }
    }

    private func receive(_ bytes: Data) {
        guard !stopping else { return }
        guard !bytes.isEmpty else { return } // termination handler owns final cleanup
        guard buffer.count + bytes.count < 32768 else { stop(reason: "renderer"); return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let next = try? JSONDecoder().decode(BoostReport.self, from: line) else { stop(reason: "renderer"); return }
            lastReport = ProcessInfo.processInfo.systemUptime
            report = next
            trace.record("report", report: next)
            onChange?()
        }
    }

    private func complete(status: Int32) {
        heartbeat?.invalidate(); heartbeat = nil
        // Drain the final report even if process termination beat the pipe callback.
        output?.readabilityHandler = nil
        if let rest = try? output?.readToEnd(), !rest.isEmpty { receive(rest) }
        try? output?.close(); output = nil
        try? input?.close(); input = nil
        process = nil
        if report.phase != "off" { report = BoostReport(phase: "off", reason: status == 75 ? "timeout" : "renderer") }
        trace.record("exit", report: report, status: status)
        onChange?()
    }
}
