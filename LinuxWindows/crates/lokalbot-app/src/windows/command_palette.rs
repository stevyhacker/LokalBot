//! The Ctrl+K command palette (`CommandPaletteView.swift`): record or stop, jump to
//! any section, open recent meetings, from a single filtered list. Typed queries
//! end with a handoff into Ask.

use crate::i18n::h_flex;
use gpui_kit::component::input::{Escape, Input, InputEvent, InputState, MoveDown, MoveUp};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, WindowBounds, WindowKind, WindowOptions, div, px, size,
};

use crate::palette::{self, PaletteCommand};
use crate::state::AppData;
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const WIDTH: f32 = 560.;
const HEIGHT: f32 = 420.;

/// Opens the palette, or brings the open one forward with its text selected.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).command_palette;
    if super::activate(existing, cx) {
        let view = super::secondary(cx)
            .command_palette_view
            .clone()
            .and_then(|view| view.upgrade());
        if let (Some(handle), Some(view)) = (existing, view) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |view, cx| view.focus_input(window, cx))
            });
        }
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = |kind| WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: true,
        show: true,
        kind,
        is_resizable: false,
        is_minimizable: false,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..Default::default()
    };
    // As Quick Recall: a borderless tool window on Windows, a normal one on X11
    // (which only gives managed windows the keyboard), a layer surface on Wayland.
    let window_kind = || {
        if cfg!(target_os = "windows") {
            WindowKind::PopUp
        } else {
            WindowKind::Normal
        }
    };
    #[cfg(target_os = "linux")]
    let layer = super::layer_surface(
        "lokalbot-command-palette",
        gpui_kit::layer_shell::Anchor::empty(),
        None,
        gpui_kit::layer_shell::KeyboardInteractivity::Exclusive,
    );
    #[cfg(not(target_os = "linux"))]
    let layer: Option<WindowKind> = None;
    let opened = match layer {
        Some(kind) => gpui_kit::open_window(options(kind), cx, build).or_else(|err| {
            log::debug!("command palette: no layer shell, opening a window: {err:#}");
            gpui_kit::open_window(options(window_kind()), cx, build)
        }),
        None => gpui_kit::open_window(options(window_kind()), cx, build),
    };
    match opened {
        Ok((handle, view)) => {
            let windows = super::secondary(cx);
            windows.command_palette = Some(handle);
            windows.command_palette_view = Some(view.downgrade());
        }
        Err(err) => log::error!("could not open the command palette: {err:#}"),
    }
}

fn build(window: &mut Window, cx: &mut App) -> Entity<CommandPalette> {
    window.set_window_title(lokalbot_i18n::tr("Command palette"));
    let view = cx.new(|cx| CommandPalette::new(window, cx));
    view.update(cx, |view, cx| view.focus_input(window, cx));
    view
}

pub struct CommandPalette {
    data: Entity<AppData>,
    input: Entity<InputState>,
    query: String,
    selection: usize,
    scroll: ScrollHandle,
    was_active: bool,
    _subscriptions: Vec<Subscription>,
}

impl CommandPalette {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Type a command or search meetings…",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        this.query = input.read(cx).value().to_string();
                        this.selection = 0;
                        cx.notify();
                    }
                    InputEvent::PressEnter { .. } => this.run_selection(window, cx),
                    _ => {}
                },
            ),
            cx.observe(&data, |_, _, cx| cx.notify()),
            cx.observe_window_activation(window, |this, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    this.close(window, cx);
                }
            }),
        ];
        Self {
            data,
            input,
            query: String::new(),
            selection: 0,
            scroll: ScrollHandle::new(),
            was_active: false,
            _subscriptions: subscriptions,
        }
    }

    fn focus_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.input.update(cx, |input, cx| {
            input.focus(window, cx);
            input.select_all(window, cx);
        });
    }

    fn results(&self, cx: &App) -> Vec<PaletteCommand> {
        palette::palette_results(self.data.read(cx), &self.query, cx)
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.results(cx).len();
        if count == 0 {
            return;
        }
        self.selection = (self.selection as isize + delta).rem_euclid(count as isize) as usize;
        self.scroll.scroll_to_item(self.selection);
        cx.notify();
    }

    fn run_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(item) = self.results(cx).get(self.selection).cloned() {
            self.run(item, window, cx);
        }
    }

    fn run(&mut self, item: PaletteCommand, window: &mut Window, cx: &mut Context<Self>) {
        self.close(window, cx);
        cx.defer(move |cx| palette::run(&item, cx));
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let windows = super::secondary(cx);
        windows.command_palette = None;
        windows.command_palette_view = None;
        window.remove_window();
    }

    fn render_row(
        &self,
        index: usize,
        item: &PaletteCommand,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = index == self.selection;
        let run_item = item.clone();
        h_flex()
            .id(("palette-row", index))
            .w_full()
            .gap(px(12.))
            .items_center()
            .px(px(10.))
            .py(px(8.))
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.accent_fill.opacity(0.15)))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(ui::icon(item.icon, px(18.), lb.accent_text))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(1.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(item.title.clone()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(item.subtitle.clone()),
                    ),
            )
            .when(selected, |this| {
                this.child(ui::icon(Ico::CornerDownLeft, px(13.), lb.text_secondary))
            })
            .on_click(
                cx.listener(move |this, _, window, cx| this.run(run_item.clone(), window, cx)),
            )
            .into_any_element()
    }
}

impl Render for CommandPalette {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let results = self.results(cx);
        let rows: Vec<AnyElement> = results
            .iter()
            .enumerate()
            .map(|(index, item)| self.render_row(index, item, cx))
            .collect();
        v_flex()
            .size_full()
            .key_context("CommandPalette")
            .font_family(FONT_FAMILY)
            .text_align(crate::i18n::interface_alignment())
            .bg(lb.elevated)
            .text_color(lb.text)
            .capture_action(cx.listener(|this, _: &MoveUp, _, cx| {
                this.move_selection(-1, cx);
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|this, _: &MoveDown, _, cx| {
                this.move_selection(1, cx);
                cx.stop_propagation();
            }))
            .on_action(cx.listener(|this, _: &Escape, window, cx| this.close(window, cx)))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .px(px(16.))
                    .py(px(12.))
                    .child(ui::icon(Ico::Terminal, px(18.), lb.accent_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(Input::new(&self.input).appearance(false).px_0()),
                    )
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child("Ctrl+K"),
                    ),
            )
            .child(ui::divider(cx))
            .child(if rows.is_empty() {
                v_flex()
                    .flex_1()
                    .items_center()
                    .justify_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::tr("No matches")))
                    .into_any_element()
            } else {
                v_flex()
                    .id("palette-results")
                    .flex_1()
                    .min_h_0()
                    .p(px(6.))
                    .gap(px(2.))
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .children(rows)
                    .into_any_element()
            })
    }
}
