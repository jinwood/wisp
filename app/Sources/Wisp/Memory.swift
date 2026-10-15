import Darwin

/// The process's physical footprint: what Activity Monitor shows as "Memory"
/// and what our budgets are measured against.
func physFootprint() -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return result == 0 ? info.ri_phys_footprint : 0
}

func formatMB(_ bytes: some BinaryInteger) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}
