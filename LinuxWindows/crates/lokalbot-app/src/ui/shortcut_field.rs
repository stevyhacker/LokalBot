//! A shortcut recorder (`ShortcutRecorder.swift`): click, then press the
//! shortcut. Escape cancels. Values read like "Ctrl+Shift+Space".

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Context, EventEmitter, FocusHandle, InteractiveElement as _, IntoElement, Keystroke,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window, div, px,
};

use super::Ico;
use crate::theme::{LbThemeExt as _, ty};

pub enum ShortcutEvent {
    /// A new, valid shortcut.
    Changed(String),
    /// Recording started or stopped, so global shortcuts can pause meanwhile.
    Recording(bool),
}

/// Returns a problem with a candidate ("Dictation already uses this shortcut…").
type Validator = Box<dyn Fn(&str, &App) -> Option<String>>;

pub struct ShortcutField {
    value: String,
    default_value: String,
    recording: bool,
    error: Option<SharedString>,
    focus: FocusHandle,
    validate: Validator,
    interceptor: Option<Subscription>,
    _blur: Subscription,
}

impl EventEmitter<ShortcutEvent> for ShortcutField {}

impl ShortcutField {
    pub fn new(
        value: impl Into<String>,
        default_value: impl Into<String>,
        validate: impl Fn(&str, &App) -> Option<String> + 'static,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let focus = cx.focus_handle();
        // Clicking elsewhere ends recording, like the macOS recorder.
        let blur = cx.on_blur(&focus, window, |this, _, cx| {
            if this.recording {
                this.stop(cx);
            }
        });
        Self {
            value: value.into(),
            default_value: default_value.into(),
            recording: false,
            error: None,
            focus,
            validate: Box::new(validate),
            interceptor: None,
            _blur: blur,
        }
    }

    pub fn set_value(&mut self, value: &str, cx: &mut Context<Self>) {
        if self.value != value && !self.recording {
            self.value = value.to_string();
            cx.notify();
        }
    }

    fn start(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.recording {
            return;
        }
        self.recording = true;
        self.error = None;
        window.focus(&self.focus, cx);
        let this = cx.entity().downgrade();
        self.interceptor = Some(cx.intercept_keystrokes(move |event, _, cx| {
            let keystroke = event.keystroke.clone();
            if is_modifier(&keystroke.key) {
                return;
            }
            cx.stop_propagation();
            let _ = this.update(cx, |field, cx| field.record(&keystroke, cx));
        }));
        cx.emit(ShortcutEvent::Recording(true));
        cx.notify();
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        self.recording = false;
        self.interceptor = None;
        cx.emit(ShortcutEvent::Recording(false));
        cx.notify();
    }

    fn record(&mut self, keystroke: &Keystroke, cx: &mut Context<Self>) {
        if keystroke.key == "escape" && !has_command_modifier(keystroke) {
            self.stop(cx);
            return;
        }
        let Some(candidate) = format_keystroke(keystroke) else {
            self.error = Some(
                lokalbot_i18n::tr("Hold the modifiers and press a key, like Ctrl+Shift+Space.")
                    .into(),
            );
            cx.notify();
            return;
        };
        if let Some(problem) = (self.validate)(&candidate, cx) {
            self.error = Some(problem.into());
            cx.notify();
            return;
        }
        self.value = candidate.clone();
        self.error = None;
        self.stop(cx);
        cx.emit(ShortcutEvent::Changed(candidate));
    }

    fn reset(&mut self, cx: &mut Context<Self>) {
        let value = self.default_value.clone();
        if (self.validate)(&value, cx).is_some() {
            return;
        }
        self.value = value.clone();
        self.error = None;
        cx.emit(ShortcutEvent::Changed(value));
        cx.notify();
    }
}

impl Render for ShortcutField {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let _ = window;
        let recording = self.recording;
        let label: SharedString = if recording {
            lokalbot_i18n::tr("Press a shortcut…").into()
        } else {
            self.value.clone().into()
        };
        v_flex()
            .items_end()
            .gap(px(4.))
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(
                        div()
                            .id("shortcut-field")
                            .track_focus(&self.focus)
                            .min_w(px(150.))
                            .h(px(28.))
                            .px(px(10.))
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(7.))
                            .border_1()
                            .border_color(if recording {
                                lb.accent_fill
                            } else {
                                lb.separator.opacity(1.6)
                            })
                            .bg(lb.elevated)
                            .cursor_pointer()
                            .text_size(ty::BODY)
                            .text_color(if recording {
                                lb.text_secondary
                            } else {
                                lb.text
                            })
                            .child(label)
                            .on_click(cx.listener(|this, _, window, cx| this.start(window, cx))),
                    )
                    .when(!recording && self.value != self.default_value, |this| {
                        this.child(
                            Button::new("shortcut-reset")
                                .ghost()
                                .xsmall()
                                .icon(Icon::new(Ico::RotateCcw))
                                .tooltip(lokalbot_i18n::format(
                                    "Reset to {0}",
                                    &[("0", self.default_value.to_string())],
                                ))
                                .on_click(cx.listener(|this, _, _, cx| this.reset(cx))),
                        )
                    }),
            )
            .when_some(self.error.clone(), |this, error| {
                this.child(
                    div()
                        .max_w(px(260.))
                        .text_size(ty::CAPTION)
                        .text_color(lb.attention_text)
                        .child(error),
                )
            })
    }
}

fn is_modifier(key: &str) -> bool {
    matches!(
        key,
        "shift" | "control" | "alt" | "platform" | "function" | "super" | "cmd" | "ctrl"
    )
}

fn has_command_modifier(keystroke: &Keystroke) -> bool {
    let m = &keystroke.modifiers;
    m.control || m.alt || m.platform
}

/// "Ctrl+Shift+Space"; `None` without Ctrl, Alt or Super.
pub fn format_keystroke(keystroke: &Keystroke) -> Option<String> {
    if !has_command_modifier(keystroke) {
        return None;
    }
    let m = &keystroke.modifiers;
    let mut parts: Vec<String> = Vec::new();
    if m.control {
        parts.push("Ctrl".into());
    }
    if m.alt {
        parts.push("Alt".into());
    }
    if m.shift {
        parts.push("Shift".into());
    }
    if m.platform {
        parts.push(if cfg!(target_os = "windows") {
            "Win".into()
        } else {
            "Super".into()
        });
    }
    parts.push(key_name(&keystroke.key));
    Some(parts.join("+"))
}

fn key_name(key: &str) -> String {
    match key {
        "space" => "Space".into(),
        "enter" => "Enter".into(),
        "tab" => "Tab".into(),
        "backspace" => "Backspace".into(),
        "delete" => "Delete".into(),
        "up" => "Up".into(),
        "down" => "Down".into(),
        "left" => "Left".into(),
        "right" => "Right".into(),
        "home" => "Home".into(),
        "end" => "End".into(),
        "pageup" => "PageUp".into(),
        "pagedown" => "PageDown".into(),
        other if other.chars().count() == 1 => other.to_uppercase(),
        other => {
            let mut chars = other.chars();
            chars
                .next()
                .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_like_the_settings_defaults() {
        let stroke = Keystroke::parse("ctrl-shift-space").unwrap();
        assert_eq!(
            format_keystroke(&stroke).as_deref(),
            Some("Ctrl+Shift+Space")
        );
        let stroke = Keystroke::parse("alt-space").unwrap();
        assert_eq!(format_keystroke(&stroke).as_deref(), Some("Alt+Space"));
        let stroke = Keystroke::parse("shift-a").unwrap();
        assert_eq!(format_keystroke(&stroke), None);
        let stroke = Keystroke::parse("ctrl-f5").unwrap();
        assert_eq!(format_keystroke(&stroke).as_deref(), Some("Ctrl+F5"));
    }
}
