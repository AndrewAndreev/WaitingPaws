import Foundation
import Observation

/// Lightweight in-app diagnostics: process CPU, main-thread CPU, memory and main-thread hangs.
/// WebKit's rendering happens in separate processes and is not included in the CPU figures.
@MainActor
@Observable
final class PerformanceMonitor {
    struct Sample: Equatable {
        var cpuTotal: Double = 0      // percent, 100 = one core
        var cpuMain: Double = 0       // percent
        var threads: Int = 0
        var memoryMB: Double = 0
        var maxHangMs: Double = 0     // worst main-thread delay in the last window
    }

    private(set) var sample = Sample()
    private(set) var isRunning = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var hangThread: Thread?
    @ObservationIgnored private var hangLock = NSLock()
    @ObservationIgnored private var worstHang: Double = 0
    @ObservationIgnored private var mainThreadID: UInt64 = 0

    nonisolated static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Hang logging runs from app launch; `start()` adds the on-screen sampling.
    func startHangLogging() {
        guard hangThread == nil else { return }
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        mainThreadID = tid
        startHangDetector()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startHangLogging()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        var s = Self.readCPU(mainThreadID: mainThreadID)
        s.memoryMB = Self.readMemoryMB()
        hangLock.lock()
        s.maxHangMs = worstHang
        worstHang = 0
        hangLock.unlock()
        sample = s
    }

    /// Pings the main queue every 100 ms and records how late the ping is served.
    private func startHangDetector() {
        let thread = Thread { [weak self] in
            while let self, !Thread.current.isCancelled {
                let sent = Date()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    let delay = Date().timeIntervalSince(sent) * 1000
                    self.hangLock.lock()
                    self.worstHang = max(self.worstHang, delay)
                    self.hangLock.unlock()
                    if delay > 250 {
                        print(String(format: "[perf] main thread hang %.0f ms at %@", delay, Self.timeFormatter.string(from: sent)))
                    }
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 5)
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "wp.hang-detector"
        thread.qualityOfService = .userInteractive
        hangThread = thread
        thread.start()
    }

    // MARK: - Mach

    nonisolated private static func readCPU(mainThreadID: UInt64) -> Sample {
        var sample = Sample()
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList else { return sample }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size))
        }
        sample.threads = Int(threadCount)
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let usage = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            sample.cpuTotal += usage

            var identifier = thread_identifier_info()
            var idCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
            let idResult = withUnsafeMutablePointer(to: &identifier) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(idCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &idCount)
                }
            }
            if idResult == KERN_SUCCESS, identifier.thread_id == mainThreadID {
                sample.cpuMain = usage
            }
        }
        return sample
    }

    nonisolated private static func readMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}
