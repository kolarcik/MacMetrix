import Darwin
import Foundation

/// Cumulative per-process counters from `proc_pidinfo` / `proc_pid_rusage`.
struct ProcStats: Codable {
    var pid: Int32
    var threads: Int
    var footprint: UInt64
    var maxFootprint: UInt64
    var pageins: UInt64
    var diskRead: UInt64
    var diskWrite: UInt64
}

/// A vnode a process holds open, or its working directory (fd -1).
struct RawOpenFile: Codable {
    enum Kind: String, Codable { case file, folder, device, cwd }
    var pid: Int32
    var fd: Int32
    var path: String
    var kind: Kind
    /// "r", "w" or "rw"; empty for the working directory.
    var mode: String
}

/// Low-level readers shared by the app (its own user's processes) and the privileged helper (all processes).
enum ProcReader {
    static func allPids() -> [Int32] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(n, 0)).filter { $0 >= 0 } // includes kernel_task (0)
    }

    /// Nil when the process can't be read (another user's process without root, or it exited).
    static func stats(_ pid: Int32) -> ProcStats? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        var task = proc_taskinfo()
        let threads = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
            ? Int(task.pti_threadnum) : -1
        return ProcStats(pid: pid, threads: threads, footprint: info.ri_phys_footprint,
                         maxFootprint: info.ri_lifetime_max_phys_footprint, pageins: info.ri_pageins,
                         diskRead: info.ri_diskio_bytesread, diskWrite: info.ri_diskio_byteswritten)
    }

    /// Working directory and every vnode the process has open (scanning all processes takes ~10–20 ms).
    static func openFiles(_ pid: Int32) -> [RawOpenFile] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var result: [RawOpenFile] = []
        var cwd = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &cwd, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let path = cString(cwd.pvi_cdir.vip_path)
            if !path.isEmpty && path != "/" {
                result.append(RawOpenFile(pid: pid, fd: -1, path: path, kind: .cwd, mode: ""))
            }
        }
        // Room for a few more descriptors opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard got > 0 else { return result }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vi = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vi,
                                 Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let path = cString(vi.pvip.vip_path)
            // /dev/null is open in nearly every process and only adds noise.
            guard !path.isEmpty, path != "/dev/null" else { continue }
            let type = vi.pvip.vip_vi.vi_stat.vst_mode & S_IFMT
            let kind: RawOpenFile.Kind = type == S_IFDIR ? .folder : (type == S_IFCHR || type == S_IFBLK) ? .device : .file
            // Kernel FREAD = 1, FWRITE = 2 (not exported to user space).
            let flags = vi.pfi.fi_openflags
            let mode = flags & 3 == 3 ? "rw" : flags & 2 != 0 ? "w" : "r"
            result.append(RawOpenFile(pid: pid, fd: fd.proc_fd, path: path, kind: kind, mode: mode))
        }
        return result
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
