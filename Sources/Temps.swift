import Foundation
import IOKit

// CPU/GPU temperatures from the SMC. Apple Silicon names its sensors Tp*/Te* (CPU cores) and Tg* (GPU).
// The prefix match fits M1, M2 and M4. M3 keeps its GPU sensors under Tf* and would need its own list.
enum Temps {
    private static var conn: io_connect_t = {
        var c: io_connect_t = 0
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        IOServiceOpen(svc, mach_task_self_, 0, &c)
        IOObjectRelease(svc)
        return c
    }()

    private static let keys: (cpu: [UInt32], gpu: [UInt32]) = {
        let count = read(fourcc("#KEY")).map { $0.bytes.reduce(0) { $0 << 8 | UInt32($1) } } ?? 0
        var cpu: [UInt32] = [], gpu: [UInt32] = []
        for i in 0..<count {
            var b = SMCParam()
            b.cmd = 8
            b.data32 = i
            guard call(&b) else { continue }
            let k = b.key, prefix = k >> 16
            guard [fourcc("Tp"), fourcc("Te"), fourcc("Tg")].contains(prefix), read(k)?.type == fourcc("flt ") else { continue }
            prefix == fourcc("Tg") ? gpu.append(k) : cpu.append(k)
        }
        return (cpu, gpu)
    }()

    static var cpu: Double? { average(keys.cpu) }
    static var gpu: Double? { average(keys.gpu) }

    private static func average(_ ks: [UInt32]) -> Double? {
        let vals = ks.compactMap { k -> Double? in
            var p = SMCParam()
            p.key = k
            p.size = 4 // every key here is a 4-byte "flt ", so skip the key-info round trip
            p.cmd = 5
            guard call(&p) else { return nil }
            let v = Double(p.raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Float.self) })
            return (10...130).contains(v) ? v : nil // idle/unused sensors report 0 or junk
        }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    // SMCKeyData_t is 80 bytes; Swift won't reproduce its C padding, so address fields by offset.
    private struct SMCParam {
        var raw = [UInt8](repeating: 0, count: 80)
        var key: UInt32 { get { u32(0) } set { put(0, newValue) } }
        var size: UInt32 { get { u32(28) } set { put(28, newValue) } }
        var type: UInt32 { u32(32) }
        var result: UInt8 { raw[40] }
        var cmd: UInt8 { get { raw[42] } set { raw[42] = newValue } }
        var data32: UInt32 { get { u32(44) } set { put(44, newValue) } }
        func u32(_ o: Int) -> UInt32 { raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        mutating func put(_ o: Int, _ v: UInt32) { raw.withUnsafeMutableBytes { $0.storeBytes(of: v, toByteOffset: o, as: UInt32.self) } }
    }

    private static func call(_ p: inout SMCParam) -> Bool {
        var out = [UInt8](repeating: 0, count: 80), n = 80
        let ok = IOConnectCallStructMethod(conn, 2, p.raw, 80, &out, &n) == KERN_SUCCESS
        p.raw = out
        return ok && p.result == 0
    }

    private static func read(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
        var info = SMCParam()
        info.key = key
        info.cmd = 9
        guard call(&info) else { return nil }
        var val = SMCParam()
        val.key = key
        val.size = info.size
        val.cmd = 5
        guard call(&val) else { return nil }
        return (info.type, Array(val.raw[48..<48 + min(Int(info.size), 32)]))
    }

    private static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}

// Load and throughput: CPU and GPU in percent, network in bytes per second. Each read costs tens of
// microseconds, next to the SMC's ~13 ms.
enum Usage {
    private struct Counters { var busy, total, rx, tx, at: UInt64 }
    private static var last: Counters?

    // Rates since the previous read. A missing or stale baseline is retaken over 0.3 s.
    static func read() -> (cpu: Double?, gpu: Double?, down: Double?, up: Double?) {
        if last == nil || DispatchTime.now().uptimeNanoseconds - last!.at > 5_000_000_000 {
            last = counters()
            usleep(300_000)
        }
        let a = last!, b = counters()
        last = b
        let secs = Double(b.at - a.at) / 1e9
        let rate = { (x: UInt64, y: UInt64) in y >= x ? Double(y - x) / secs : nil } // nil if a counter reset
        let cpu = b.total > a.total && b.busy >= a.busy ? Double(b.busy - a.busy) / Double(b.total - a.total) * 100 : nil
        return (cpu, gpu(), rate(a.rx, b.rx), rate(a.tx, b.tx))
    }

    // Memory the way Activity Monitor breaks it down, in bytes. Used is app memory, wired and compressed;
    // cached files are what macOS can hand back at once. Pressure is the kernel's level: 1 normal, 2 warning, 4 critical.
    struct Memory { var used, total, app, wired, compressed, cached, swap: Double; var pressure: Int32 }

    // Microseconds to read.
    static var memory: Memory? {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        guard ok == KERN_SUCCESS else { return nil }
        let bytes = { (pages: UInt64) in Double(pages * UInt64(vm_kernel_page_size)) }
        let app = bytes(UInt64(s.internal_page_count) - UInt64(s.purgeable_count))
        let wired = bytes(UInt64(s.wire_count)), compressed = bytes(UInt64(s.compressor_page_count))
        var swap = xsw_usage(), pressure: Int32 = 0
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        return Memory(used: app + wired + compressed, total: Double(ProcessInfo.processInfo.physicalMemory),
                      app: app, wired: wired, compressed: compressed,
                      cached: bytes(UInt64(s.external_page_count) + UInt64(s.purgeable_count)),
                      swap: Double(swap.xsu_used), pressure: pressure)
    }

    // Free space as Finder counts it (purgeable space is free). ~4 ms, so it's read when the panel opens.
    static var disk: (free: Double, total: Double)? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let free = v?.volumeAvailableCapacityForImportantUsage, let total = v?.volumeTotalCapacity, total > 0 else { return nil }
        return (Double(free), Double(total))
    }

    // The GPU driver's own figure, the one Activity Monitor shows.
    private static func gpu() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var result: Double?
        while case let entry = IOIteratorNext(it), entry != 0 {
            let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            if let v = stats?["Device Utilization %"] as? Int { result = max(result ?? 0, Double(v)) }
            IOObjectRelease(entry)
        }
        return result
    }

    private static func counters() -> Counters {
        var c = Counters(busy: 0, total: 0, rx: 0, tx: 0, at: DispatchTime.now().uptimeNanoseconds)
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0, cpus: natural_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info {
            for i in 0..<Int(cpus) {
                let t = { (s: Int32) in UInt64(UInt32(bitPattern: info[i * Int(CPU_STATE_MAX) + Int(s)])) }
                let busy = t(CPU_STATE_USER) + t(CPU_STATE_SYSTEM) + t(CPU_STATE_NICE)
                c.busy += busy
                c.total += busy + t(CPU_STATE_IDLE)
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        // Network: 64-bit byte counters of the physical interfaces (en*). getifaddrs' are 32-bit and wrap every 4 GB.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return c }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return c }
        buf.withUnsafeBytes { p in
            var o = 0, name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            while o + MemoryLayout<if_msghdr>.size <= len {
                let h = p.loadUnaligned(fromByteOffset: o, as: if_msghdr.self)
                if Int32(h.ifm_type) == RTM_IFINFO2 {
                    let m = p.loadUnaligned(fromByteOffset: o, as: if_msghdr2.self)
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        c.rx += m.ifm_data.ifi_ibytes
                        c.tx += m.ifm_data.ifi_obytes
                    }
                }
                guard h.ifm_msglen > 0 else { break }
                o += Int(h.ifm_msglen)
            }
        }
        return c
    }
}
