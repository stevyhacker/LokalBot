//! One module per sidebar destination. Each page is a GPUI view that also
//! supplies its toolbar title and items to the window shell.

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
    /// Title shown at the left of the toolbar.
    fn title(&self, cx: &App) -> SharedString;

    /// Toolbar items shown at the right of the toolbar.
    fn toolbar(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> Option<AnyElement> {
        None
    }
}
