import Foundation
import Darwin

/// A renewable health lease, independent of the worker's main run loop.
/// Only completed health/render ticks renew it; elapsed session time is irrelevant.
final class WorkerWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline = ProcessInfo.processInfo.systemUptime + 3
    private var timer: DispatchSourceTimer?

    func renew() {
        lock.lock()
        deadline = ProcessInfo.processInfo.systemUptime + 3
        lock.unlock()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let expired = ProcessInfo.processInfo.systemUptime >= self.deadline
            self.lock.unlock()
            if expired { _exit(75) }
        }
        self.timer = timer
        timer.resume()
    }
}
