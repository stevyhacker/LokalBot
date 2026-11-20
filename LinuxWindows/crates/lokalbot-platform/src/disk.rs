use std::path::Path;

#[cfg(target_os = "linux")]
pub fn available_bytes(path: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt as _;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(path.as_ptr(), &mut stats) } != 0 {
        return None;
    }
    #[allow(clippy::useless_conversion)]
    Some(u64::from(stats.f_bavail).saturating_mul(u64::from(stats.f_frsize)))
}

#[cfg(windows)]
pub fn available_bytes(path: &Path) -> Option<u64> {
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    use windows::core::HSTRING;
    let mut free = 0u64;
    unsafe { GetDiskFreeSpaceExW(&HSTRING::from(path), Some(&mut free), None, None) }.ok()?;
    Some(free)
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn available_bytes(_path: &Path) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    #[test]
    fn reports_something_for_a_real_folder() {
        let dir = std::env::temp_dir();
        assert!(super::available_bytes(&dir).is_some_and(|free| free > 0));
    }
}
