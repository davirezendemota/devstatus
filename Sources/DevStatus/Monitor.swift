import Foundation
import Darwin
import IOKit
import IOKit.ps

// MARK: Modelos

struct CPUInfo {
    var usage: Double = 0        // 0-1
    var user: Double = 0
    var system: Double = 0
    var load: (Double, Double, Double) = (0, 0, 0)
    var cores = ProcessInfo.processInfo.activeProcessorCount
}

struct MemoryInfo {
    var total: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var used: Double = 0         // app + wired + comprimida (como o Monitor de Atividade)
    var wired: Double = 0
    var compressed: Double = 0
    var swapUsed: Double = 0
}

struct DiskInfo: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let total: Double
    let free: Double
    let isInternal: Bool
    var used: Double { total - free }
}

struct TemperatureInfo {
    var cpu: Double?
    var ssd: Double?
    var battery: Double?
    var hottest: (name: String, value: Double)?
    var thermalState: ProcessInfo.ThermalState = .nominal
}

struct NetworkInfo {
    var down: Double = 0         // bytes/s
    var up: Double = 0
    var totalDown: Double = 0    // desde o boot
    var totalUp: Double = 0
    var interface: String?
    var ip: String?
}

struct BatteryInfo {
    var percent: Double
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?        // ate esvaziar ou ate carregar
    var cycles: Int?
    var health: Double?          // capacidade atual / de fabrica
}

// MARK: Store

/// Le metricas do sistema (so APIs locais do macOS) no intervalo de Stats › Monitor, enquanto a aba ou o icone estiverem ativos.
@MainActor
final class MonitorStore: ObservableObject {
    @Published var cpu = CPUInfo()
    @Published var memory = MemoryInfo()
    @Published var disks: [DiskInfo] = []
    @Published var temperature = TemperatureInfo()
    @Published var network = NetworkInfo()
    @Published var battery: BatteryInfo?
    @Published var cpuHistory: [Double] = []
    @Published var downHistory: [Double] = []
    @Published var upHistory: [Double] = []

    private var timer: Timer?
    private var users = 0
    private var lastTicks: [UInt32]?
    private var lastNet: (date: Date, down: UInt64, up: UInt64)?
    private let historySize = 40

    func start() {
        users += 1
        guard timer == nil else { return }
        sample()
        scheduleTimer()
    }

    private var interval: Double = Stat.monitor.interval

    func setInterval(_ seconds: Double) {
        guard seconds != interval else { return }
        interval = seconds
        if timer != nil { scheduleTimer() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Mantem a leitura ligada enquanto o icone de Monitor estiver na barra.
    private var background = false
    func setBackground(_ on: Bool) {
        guard on != background else { return }
        background = on
        on ? start() : stop()
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate(); timer = nil
    }

    func sample() {
        sampleCPU()
        memory = SystemStats.memory()
        disks = SystemStats.disks()
        temperature = Sensors.read()
        sampleNetwork()
        battery = SystemStats.battery()
    }

    private func push(_ v: Double, _ h: inout [Double]) {
        h.append(v)
        if h.count > historySize { h.removeFirst(h.count - historySize) }
    }

    private func sampleCPU() {
        guard let t = SystemStats.cpuTicks() else { return }
        if let l = lastTicks {
            let d = zip(t, l).map { Double($0 &- $1) }
            let total = d.reduce(0, +)
            if total > 0 {
                cpu.user = (d[0] + d[3]) / total      // user + nice
                cpu.system = d[1] / total
                cpu.usage = cpu.user + cpu.system
                push(cpu.usage, &cpuHistory)
            }
        }
        lastTicks = t
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { cpu.load = (l[0], l[1], l[2]) }
    }

    private func sampleNetwork() {
        guard let n = SystemStats.networkBytes() else { return }
        let now = Date()
        if let last = lastNet {
            let dt = now.timeIntervalSince(last.date)
            if dt > 0 {
                network.down = Double(n.down &- last.down) / dt
                network.up = Double(n.up &- last.up) / dt
                push(network.down, &downHistory)
                push(network.up, &upHistory)
            }
        }
        lastNet = (now, n.down, n.up)
        network.totalDown = Double(n.down)
        network.totalUp = Double(n.up)
        let primary = SystemStats.primaryInterface()
        network.interface = primary?.name
        network.ip = primary?.ip
    }
}

// MARK: Leituras

enum SystemStats {
    /// Ticks de CPU: user, system, idle, nice.
    static func cpuTicks() -> [UInt32]? {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = load.cpu_ticks
        return [t.0, t.1, t.2, t.3]
    }

    static func memory() -> MemoryInfo {
        var info = MemoryInfo()
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(s.internal_page_count) - Double(s.purgeable_count)
            info.wired = Double(s.wire_count) * page
            info.compressed = Double(s.compressor_page_count) * page
            info.used = app * page + info.wired + info.compressed
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { info.swapUsed = Double(swap.xsu_used) }
        return info
    }

    /// Volumes visiveis no Finder (internos e externos).
    static func disks() -> [DiskInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0,
                  url.path == "/" || url.path.hasPrefix("/Volumes/") else { return nil }  // ignora discos virtuais (OrbStack etc.)
            let free = v.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? Double(v.volumeAvailableCapacity ?? 0)
            return DiskInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path, total: Double(total),
                            free: free, isInternal: v.volumeIsInternal ?? false)
        }
        .sorted { ($0.path == "/" ? 0 : 1, $0.name) < ($1.path == "/" ? 0 : 1, $1.name) }
    }

    /// Bytes recebidos/enviados desde o boot, somando as interfaces (exceto loopback). Contadores de 64 bits.
    static func networkBytes() -> (down: UInt64, up: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var down: UInt64 = 0, up: UInt64 = 0
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: offset, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil, !String(cString: name).hasPrefix("lo") {
                        down += h2.ifm_data.ifi_ibytes
                        up += h2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(hdr.ifm_msglen)
            }
        }
        return (down, up)
    }

    /// Primeira interface en* com IPv4 (Wi-Fi/Ethernet).
    static func primaryInterface() -> (name: String, ip: String)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: [(String, String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (a.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((name, String(cString: host)))
            }
        }
        return found.sorted { $0.0 < $1.0 }.first.map { (name: $0.0, ip: $0.1) }
    }

    static func battery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = Util.num(d[kIOPSCurrentCapacityKey]) ?? 0
            let max = Util.num(d[kIOPSMaxCapacityKey]) ?? 100
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            var info = BatteryInfo(percent: max > 0 ? cur / max * 100 : cur, charging: charging, onAC: onAC,
                                   minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if svc != 0 {
                defer { IOObjectRelease(svc) }
                func prop(_ k: String) -> Any? {
                    IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                info.cycles = prop("CycleCount") as? Int
                if let bd = prop("BatteryData") as? [String: Any],
                   let design = Util.num(bd["DesignCapacity"]), design > 0,
                   let nominal = Util.num(bd["NominalChargeCapacity"]) ?? Util.num(bd["AppleRawMaxCapacity"]) {
                    info.health = min(nominal / design * 100, 100)
                }
            }
            return info
        }
        return nil
    }
}

// MARK: Temperatura (sensores HID; API privada do IOKit, so leitura)

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> CFTypeRef?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> CFTypeRef?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

enum Sensors {
    private static let temperatureEvent: Int64 = 15
    private static let client: CFTypeRef? = {
        guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        // Pagina de uso da Apple (0xff00), uso 5 = sensor de temperatura.
        _ = IOHIDEventSystemClientSetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        return c
    }()

    static func read() -> TemperatureInfo {
        var info = TemperatureInfo(thermalState: ProcessInfo.processInfo.thermalState)
        guard let c = client, let services = IOHIDEventSystemClientCopyServices(c) as? [CFTypeRef] else { return info }
        var cpu: [Double] = [], ssd: [Double] = [], battery: [Double] = []
        for s in services {
            guard let name = IOHIDServiceClientCopyProperty(s, "Product" as CFString) as? String,
                  let e = IOHIDServiceClientCopyEvent(s, temperatureEvent, 0, 0) else { continue }
            let v = IOHIDEventGetFloatValue(e, Int32(temperatureEvent << 16))
            guard v > 0, v < 130 else { continue }   // descarta leituras invalidas
            if name.contains("tdie") { cpu.append(v) }
            else if name.contains("NAND") { ssd.append(v) }
            else if name.lowercased().contains("battery") { battery.append(v) }
            if v > (info.hottest?.value ?? 0) { info.hottest = (name, v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        info.cpu = avg(cpu); info.ssd = avg(ssd); info.battery = avg(battery)
        return info
    }
}
