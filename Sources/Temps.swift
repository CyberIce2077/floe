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

// CPU and GPU load in percent. Each read costs tens of microseconds, next to the SMC's ~13 ms.
enum Usage {
    private static var last: (busy: UInt64, total: UInt64, at: UInt64)?

    // Busy share of all cores since the previous read. A missing or stale sample is retaken over 0.3 s.
    static var cpu: Double? {
        if last == nil || DispatchTime.now().uptimeNanoseconds - last!.at > 5_000_000_000 {
            last = ticks()
            usleep(300_000)
        }
        let prev = last!, now = ticks()
        last = now
        guard now.total > prev.total, now.busy >= prev.busy else { return nil } // counters wrapped
        return Double(now.busy - prev.busy) / Double(now.total - prev.total) * 100
    }

    // The GPU driver's own figure, the one Activity Monitor shows.
    static var gpu: Double? {
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

    private static func ticks() -> (busy: UInt64, total: UInt64, at: UInt64) {
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0, cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return (0, 0, DispatchTime.now().uptimeNanoseconds) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, idle: UInt64 = 0
        for c in 0..<Int(cpus) {
            let t = { (s: Int32) in UInt64(UInt32(bitPattern: info[c * Int(CPU_STATE_MAX) + Int(s)])) }
            busy += t(CPU_STATE_USER) + t(CPU_STATE_SYSTEM) + t(CPU_STATE_NICE)
            idle += t(CPU_STATE_IDLE)
        }
        return (busy, busy + idle, DispatchTime.now().uptimeNanoseconds)
    }
}
