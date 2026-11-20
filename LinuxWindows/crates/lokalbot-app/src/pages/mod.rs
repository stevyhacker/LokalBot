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
    fn title(&self, cx: &App) -> SharedString;

    fn subtitle(&self, _cx: &App) -> Option<SharedString> {
        None
    }

    fn toolbar(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> Option<AnyElement> {
        None
    }

    fn title_control(
        &mut self,
        _window: &mut Window,
        _cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        None
    }
}
