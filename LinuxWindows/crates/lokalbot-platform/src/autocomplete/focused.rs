use super::policy::ReadPolicy;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Field {
    pub pid: u32,
    pub key: String,
    pub editable: bool,
    pub secure: bool,
    pub terminal: bool,
    pub selection: Option<(i32, i32)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FieldRead {
    Silent,
    NoFocus,
    Field(Field),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionRead {
    Text(String),
    Empty,
    Secure,
    Unavailable,
}

pub fn read_field(pid: Option<u32>) -> FieldRead {
    #[cfg(target_os = "linux")]
    {
        super::atspi::focused::read_field(pid)
    }
    #[cfg(windows)]
    {
        super::uia::focused::read_field(pid)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = pid;
        FieldRead::Silent
    }
}

pub fn selected_text(pid: u32, max_characters: usize) -> SelectionRead {
    #[cfg(target_os = "linux")]
    {
        super::atspi::focused::selected_text(pid, max_characters)
    }
    #[cfg(windows)]
    {
        super::uia::focused::selected_text(pid, max_characters)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (pid, max_characters);
        SelectionRead::Unavailable
    }
}

pub fn text_before_caret(pid: u32, identity: &str) -> Option<String> {
    if identity.is_empty() {
        return None;
    }
    #[cfg(target_os = "linux")]
    {
        super::atspi::focused::text_before_caret(pid, identity)
    }
    #[cfg(windows)]
    {
        super::uia::focused::text_before_caret(pid, identity)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = pid;
        None
    }
}

pub fn visible_text(
    pid: u32,
    identity: &str,
    app_name: &str,
    app_id: &str,
    policy: &ReadPolicy,
) -> Option<String> {
    if identity.is_empty() {
        return None;
    }
    #[cfg(target_os = "linux")]
    {
        super::atspi::focused::visible_text(pid, identity, app_name, app_id, policy)
    }
    #[cfg(windows)]
    {
        super::uia::focused::visible_text(pid, identity, app_name, app_id, policy)
    }
    #[cfg(not(any(windows, target_os = "linux")))]
    {
        let _ = (pid, app_name, app_id, policy);
        None
    }
}

#[cfg(target_os = "linux")]
pub(crate) fn active_pid() -> Option<u32> {
    super::atspi::focused::active_pid()
}
