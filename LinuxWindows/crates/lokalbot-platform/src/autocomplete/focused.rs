//! Reads of the focused field for dictation and selection actions
//! (`CotypingAXHelper.resolveDictationFocusSnapshot`,
//! `selectedTextForSelectionAction`, `dictationTextBeforeCaret`). Unlike
//! [`super::FieldWatcher`], nothing runs until a shortcut asks, and only what a
//! call names is read. Blocking: call them from a background thread.

use super::policy::ReadPolicy;

/// What accessibility says about the focused element. Carries no field text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Field {
    pub pid: u32,
    /// The toolkit's identity for the element.
    pub key: String,
    pub editable: bool,
    /// A password or other secure field; nothing else about it was read.
    pub secure: bool,
    pub terminal: bool,
    /// The selection's start and end offsets, when it is not empty.
    pub selection: Option<(i32, i32)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FieldRead {
    /// No accessibility answer: the bus is down or the app publishes nothing.
    Silent,
    /// The app answers, and nothing in it has focus.
    NoFocus,
    Field(Field),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectionRead {
    Text(String),
    /// An editable field with nothing selected.
    Empty,
    Secure,
    /// The app did not say.
    Unavailable,
}

/// The focused element of `pid`; without a pid, of the app whose window is
/// active.
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

/// The selected text in `pid`'s focused element, read once.
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

/// The bounded text before the caret, only while the bound field has focus
/// and is not secure. `None` makes no claim either way.
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

/// The text shown just above the bound field, when `policy` allows it, read
/// and validated once.
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

/// The process whose window is active, where only accessibility can say.
#[cfg(target_os = "linux")]
pub(crate) fn active_pid() -> Option<u32> {
    super::atspi::focused::active_pid()
}
