//! Spoken summaries from the meeting menu (`MeetingWorkspaceView.readSummary`,
//! `exportSpokenSummary`).

use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::{Context, WeakEntity};
use lokalbot_engine::{Command, SpeechCommand};

use super::MeetingsPage;

fn key(meeting: uuid::Uuid) -> String {
    format!("meeting:{meeting}")
}

impl MeetingsPage {
    fn reading_summary(&self, cx: &gpui_kit::App) -> bool {
        let Some(doc) = self.doc.as_ref() else {
            return false;
        };
        self.data.read(cx).speech.reading.as_deref() == Some(key(doc.meeting.id).as_str())
    }

    fn toggle_spoken_summary(&mut self, cx: &mut Context<Self>) {
        if self.reading_summary(cx) {
            crate::bridge::send(Command::Speech(SpeechCommand::Stop), cx);
            return;
        }
        let Some(doc) = self.doc.as_ref() else { return };
        let Some(text) = doc.summary.clone().filter(|s| !s.trim().is_empty()) else {
            return;
        };
        crate::bridge::send(
            Command::Speech(SpeechCommand::Read {
                key: key(doc.meeting.id),
                text,
            }),
            cx,
        );
    }

    fn export_spoken_summary(&mut self, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        let Some(text) = doc.summary.clone().filter(|s| !s.trim().is_empty()) else {
            return;
        };
        let name = format!(
            "{}-spoken-summary.wav",
            lokalbot_core::ids::slugify(&doc.meeting.display_title())
        );
        let receiver = cx.prompt_for_new_path(&super::directories_home(), Some(&name));
        cx.spawn(async move |_, cx| {
            let Ok(Ok(Some(path))) = receiver.await else {
                return;
            };
            cx.update(|cx| {
                crate::bridge::send(Command::Speech(SpeechCommand::Export { text, path }), cx)
            });
        })
        .detach();
    }

    /// The meeting being read is no longer the one shown.
    pub(super) fn stop_spoken_summary(&mut self, cx: &mut Context<Self>) {
        if self.reading_summary(cx) {
            crate::bridge::send(Command::Speech(SpeechCommand::Stop), cx);
        }
    }

    /// "Read summary aloud" and "Export spoken summary" for the More menu.
    pub(super) fn spoken_menu_items(&self, cx: &gpui_kit::App) -> SpokenMenu {
        SpokenMenu {
            has_summary: self.doc.as_ref().is_some_and(|d| d.has_summary()),
            reading: self.reading_summary(cx),
            exporting: self.data.read(cx).speech.exporting,
        }
    }
}

/// The More menu's spoken summary state when it was built.
#[derive(Clone, Copy)]
pub(super) struct SpokenMenu {
    has_summary: bool,
    reading: bool,
    exporting: bool,
}

impl SpokenMenu {
    pub(super) fn add(self, menu: PopupMenu, page: WeakEntity<MeetingsPage>) -> PopupMenu {
        let toggle = page.clone();
        menu.item(
            PopupMenuItem::new(if self.reading {
                lokalbot_i18n::tr("Stop spoken summary")
            } else {
                lokalbot_i18n::tr("Read summary aloud")
            })
            .disabled(!self.has_summary)
            .on_click(move |_, _, cx| {
                let _ = toggle.update(cx, |this, cx| this.toggle_spoken_summary(cx));
            }),
        )
        .item(
            PopupMenuItem::new(if self.exporting {
                lokalbot_i18n::tr("Exporting spoken summary...")
            } else {
                lokalbot_i18n::tr("Export spoken summary")
            })
            .disabled(self.exporting || !self.has_summary)
            .on_click(move |_, _, cx| {
                let _ = page.update(cx, |this, cx| this.export_spoken_summary(cx));
            }),
        )
    }
}
