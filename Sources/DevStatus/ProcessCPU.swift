import Darwin

/// Uso de CPU por app, como no Monitor de Atividade (100% = um nucleo inteiro).
/// Soma o processo principal e os descendentes (ex.: processos auxiliares do Chrome).
final class ProcessCPU {
    private var lastCPU: [pid_t: UInt64] = [:]
    private var lastWall: UInt64 = 0

    /// Devolve o % de CPU de cada pid raiz desde a chamada anterior (vazio na primeira).
    func sample(roots: Set<pid_t>) -> [pid_t: Double] {
        let pids = allPids()
        let now = mach_absolute_time()
        var parent: [pid_t: pid_t] = [:]
        var cpu: [pid_t: UInt64] = [:]
        for pid in pids {
            var bsd = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parent[pid] = pid_t(bsd.pbi_ppid)
            }
            var task = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                cpu[pid] = task.pti_total_user + task.pti_total_system
            }
        }

        var result: [pid_t: Double] = [:]
        // Tempo de CPU e relogio estao na mesma unidade (ticks do mach), entao a razao ja e a fracao.
        if lastWall > 0, now > lastWall {
            let wall = Double(now - lastWall)
            for (pid, t) in cpu {
                guard let prev = lastCPU[pid], t >= prev, let root = root(of: pid, roots: roots, parent: parent) else { continue }
                result[root, default: 0] += Double(t - prev) / wall * 100
            }
        }
        lastCPU = cpu
        lastWall = now
        return result
    }

    private func root(of pid: pid_t, roots: Set<pid_t>, parent: [pid_t: pid_t]) -> pid_t? {
        var p = pid
        for _ in 0..<32 {
            if roots.contains(p) { return p }
            guard let pp = parent[p], pp > 1, pp != p else { return nil }
            p = pp
        }
        return nil
    }

    private func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(got, 0))))
    }
}
