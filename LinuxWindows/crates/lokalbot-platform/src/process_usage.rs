//! What one process has used so far (`SystemResourceSampler`): CPU time and
//! resident memory, from `/proc` on Linux and the process APIs on Windows.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProcessUsage {
    /// User and kernel time since it started.
    pub cpu_seconds: f64,
    pub memory_bytes: u64,
}

/// Installed memory, for choosing a model preset.
#[cfg(target_os = "linux")]
pub fn total_memory_bytes() -> Option<u64> {
    let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
    let line = meminfo.lines().find(|line| line.starts_with("MemTotal:"))?;
    let kilobytes: u64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kilobytes * 1024)
}

#[cfg(target_os = "windows")]
pub fn total_memory_bytes() -> Option<u64> {
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut status = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        ..Default::default()
    };
    // SAFETY: the struct is initialized and its length field set, as the API requires.
    unsafe { GlobalMemoryStatusEx(&mut status) }.ok()?;
    Some(status.ullTotalPhys)
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn total_memory_bytes() -> Option<u64> {
    None
}

/// `None` when the process is gone or can't be read.
#[cfg(target_os = "linux")]
pub fn process_usage(pid: u32) -> Option<ProcessUsage> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    parse_proc(&stat, &status)
}

#[cfg(target_os = "windows")]
pub fn process_usage(pid: u32) -> Option<ProcessUsage> {
    use windows::Win32::Foundation::{CloseHandle, FILETIME};
    use windows::Win32::System::ProcessStatus::{K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
    use windows::Win32::System::Threading::{
        GetProcessTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    fn seconds(time: FILETIME) -> f64 {
        let ticks = (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime);
        ticks as f64 / 10_000_000.0
    }

    // SAFETY: the handle is checked, used only here and closed before returning,
    // and the out-parameters are valid for the calls.
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let (mut created, mut exited, mut kernel, mut user) = (
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
            FILETIME::default(),
        );
        let times = GetProcessTimes(process, &mut created, &mut exited, &mut kernel, &mut user);
        let mut counters = PROCESS_MEMORY_COUNTERS::default();
        let memory = K32GetProcessMemoryInfo(
            process,
            &mut counters,
            std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32,
        );
        let _ = CloseHandle(process);
        times.ok()?;
        if !memory.as_bool() {
            return None;
        }
        Some(ProcessUsage {
            cpu_seconds: seconds(kernel) + seconds(user),
            memory_bytes: counters.WorkingSetSize as u64,
        })
    }
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn process_usage(_pid: u32) -> Option<ProcessUsage> {
    None
}

/// `/proc/<pid>/stat` counts in `USER_HZ`, which is 100 on the platforms we ship.
#[cfg(any(target_os = "linux", test))]
fn parse_proc(stat: &str, status: &str) -> Option<ProcessUsage> {
    const TICKS_PER_SECOND: f64 = 100.0;
    // The process name can hold spaces and parentheses; fields resume after the last `)`.
    let rest = stat.rsplit_once(')')?.1;
    let mut fields = rest.split_whitespace();
    // utime and stime are fields 14 and 15; `rest` starts at field 3.
    let utime: f64 = fields.nth(11)?.parse().ok()?;
    let stime: f64 = fields.next()?.parse().ok()?;
    let kilobytes: u64 = status
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()?;
    Some(ProcessUsage {
        cpu_seconds: (utime + stime) / TICKS_PER_SECOND,
        memory_bytes: kilobytes * 1024,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proc_files_parse_despite_odd_process_names() {
        let stat = "1234 (llama (server) x) S 1 2 3 4 5 6 7 8 9 10 250 150 0 0 20 0";
        let status = "Name:\tllama\nVmPeak:\t  9 kB\nVmRSS:\t    2048 kB\nThreads:\t4\n";
        let usage = parse_proc(stat, status).unwrap();
        assert!((usage.cpu_seconds - 4.0).abs() < 1e-9);
        assert_eq!(usage.memory_bytes, 2_097_152);
        assert_eq!(parse_proc("nonsense", status), None);
        assert_eq!(parse_proc(stat, "Name:\tgone\n"), None);
    }

    #[cfg(any(target_os = "linux", target_os = "windows"))]
    #[test]
    fn this_process_can_be_read() {
        let usage = process_usage(std::process::id()).unwrap();
        assert!(usage.memory_bytes > 0);
        assert!(usage.cpu_seconds >= 0.0);
        assert_eq!(process_usage(u32::MAX), None);
    }
}
