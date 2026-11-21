#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProcessUsage {
    pub cpu_seconds: f64,
    pub memory_bytes: u64,
}

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
    unsafe { GlobalMemoryStatusEx(&mut status) }.ok()?;
    Some(status.ullTotalPhys)
}

#[cfg(not(any(target_os = "linux", target_os = "windows")))]
pub fn total_memory_bytes() -> Option<u64> {
    None
}

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

#[cfg(any(target_os = "linux", test))]
fn parse_proc(stat: &str, status: &str) -> Option<ProcessUsage> {
    const TICKS_PER_SECOND: f64 = 100.0;
    let rest = stat.rsplit_once(')')?.1;
    let mut fields = rest.split_whitespace();
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
