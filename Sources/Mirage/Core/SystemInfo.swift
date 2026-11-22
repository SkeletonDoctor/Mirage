import Foundation
import AppKit
import Metal
import Darwin

/// Static facts about this Mac, read once at launch.
struct SystemInfo {
    let chip: String
    let totalMemory: UInt64
    let performanceCores: Int
    let efficiencyCores: Int
    let gpuName: String
    /// Metal's recommended ceiling for GPU allocations. MLX treats this as its working budget.
    let gpuWorkingSet: UInt64
    let osVersion: String
    let isAppleSilicon: Bool

    static let current = SystemInfo.load()

    var totalGB: Double { Double(totalMemory) / 1_073_741_824 }
    var gpuWorkingSetGB: Double { Double(gpuWorkingSet) / 1_073_741_824 }

    private static func load() -> SystemInfo {
        let device = MTLCreateSystemDefaultDevice()
        let total = ProcessInfo.processInfo.physicalMemory
        let workingSet = device?.recommendedMaxWorkingSetSize ?? UInt64(Double(total) * 0.7)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0)
        return SystemInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            totalMemory: total,
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount,
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            gpuName: device?.name ?? "Unknown GPU",
            gpuWorkingSet: workingSet,
            osVersion: "\(v.majorVersion).\(v.minorVersion)",
            isAppleSilicon: arm == 1
        )
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// Live memory readings.
enum MemoryProbe {
    /// Memory the system can hand out without swapping: free + inactive + purgeable pages.
    static func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)) * page
    }

    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// Physical footprint of another process (what Activity Monitor calls "Memory").
    static func footprint(pid: pid_t) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : 0
    }
}

enum PressureLevel: Int, Comparable {
    case normal = 0, warning = 1, critical = 2
    static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Under pressure"
        case .critical: return "Critical"
        }
    }
}

/// Polls memory once a second and listens for the kernel's memory-pressure signal.
@Observable @MainActor
final class MemoryMonitor {
    static let shared = MemoryMonitor()

    private(set) var availableGB: Double = 0
    private(set) var swapGB: Double = 0
    private(set) var pressure: PressureLevel = .normal
    /// Footprint of the running generation process, if any.
    private(set) var jobGB: Double = 0

    var watchedPID: pid_t? { didSet { if watchedPID == nil { jobGB = 0 } } }
    /// Called on the main actor when pressure turns critical.
    var onCritical: (() -> Void)?

    private var timer: Timer?
    private var source: DispatchSourceMemoryPressure?
    private var criticalSince: Date?

    var usedFraction: Double {
        let total = SystemInfo.current.totalGB
        return total > 0 ? max(0, min(1, 1 - availableGB / total)) : 0
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let event = src.data
            Task { @MainActor in
                if event.contains(.critical) { self.pressure = .critical }
                else if event.contains(.warning) { self.pressure = .warning }
                else { self.pressure = .normal }
                // Under pressure, give back what the app can: its decoded images and thumbnails.
                if self.pressure != .normal { ThumbnailCache.shared.purge(); ImageLoader.shared.purge() }
            }
        }
        src.resume()
        source = src
    }

    private var tick = 0

    private func sample() {
        // Every second while a model runs; every third second otherwise, and less still in the background.
        tick += 1
        let idleEvery = NSApp?.isActive == false ? 6 : 3
        if watchedPID == nil && tick % idleEvery != 0 && tick > 1 { return }

        // Only publish values that visibly changed, so the interface is not redrawn for nothing.
        let available = (Double(MemoryProbe.availableBytes()) / 1_073_741_824 * 10).rounded() / 10
        if available != availableGB { availableGB = available }
        let swap = (Double(MemoryProbe.swapUsedBytes()) / 1_073_741_824 * 10).rounded() / 10
        if swap != swapGB { swapGB = swap }
        if let pid = watchedPID {
            let job = (Double(MemoryProbe.footprint(pid: pid)) / 1_073_741_824 * 10).rounded() / 10
            if job != jobGB { jobGB = job }
        }

        // Only escalate after the critical state has held for a few seconds, so a brief spike
        // while a model loads doesn't kill a generation that would have finished.
        if pressure == .critical {
            if criticalSince == nil { criticalSince = Date() }
            if let since = criticalSince, Date().timeIntervalSince(since) > 8 {
                criticalSince = nil
                onCritical?()
            }
        } else {
            criticalSince = nil
        }
    }
}
