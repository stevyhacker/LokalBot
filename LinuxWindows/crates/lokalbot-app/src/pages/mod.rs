//! One module per sidebar destination. Each page is a GPUI view that also
//! supplies its toolbar title, subtitle and items to the window shell.
//! Settings is not a page of the main window: it has its own window
//! (`windows::settings`).

pub mod actions;
pub mod agent;
pub mod ask;
pub mod meetings;
pub mod people;
pub mod projects;
pub mod settings;
pub mod timeline;
pub mod today;

use gpui_kit::{AnyElement, App, Context, Render, SharedString, Window};

pub trait Page: Render + Sized {
    /// Title shown at the leading edge of the toolbar, as the Mac shows a
    /// section's `navigationTitle`.
    fn title(&self, cx: &App) -> SharedString;

    /// A smaller second line under the title (`navigationSubtitle`): Today's
    /// date, Actions' "2 open". Every section's toolbar keeps the same
    /// height with or without it.
    fn subtitle(&self, _cx: &App) -> Option<SharedString> {
        None
    }

    /// Toolbar items shown at the right of the toolbar.
    fn toolbar(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> Option<AnyElement> {
        None
    }

    /// A control drawn in the title's place, as Timeline's date opens its
    /// calendar. `None` draws `title` and `subtitle` as text.
    fn title_control(
        &mut self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        None
    }
}
