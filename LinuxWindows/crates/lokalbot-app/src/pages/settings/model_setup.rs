//! Safe model switching (`ModelSetupController`, `ModelSelectionPatch`): the
//! replacement is prepared first and the settings change only once it is ready,
//! so the current models stay active until then.

use std::collections::HashSet;

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{
    AnyElement, App, Context, Entity, FontWeight, IntoElement as _, ParentElement as _,
    SharedString, Styled as _, div, px,
};
use lokalbot_core::Settings;
use lokalbot_core::access::remote_block_reason;
use lokalbot_core::remote_transcription::RemoteTranscription;
use lokalbot_core::settings::{SubscriptionPlan, SummarizerBackend};

use super::SettingsPage;
use super::models::RUNTIME_ID;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// A deliberately narrow patch: applying or undoing a switch never overwrites
/// privacy choices, credentials or unrelated edits made during a download.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ModelPatch {
    pub transcription: Option<String>,
    pub remote_transcription_base_url: Option<String>,
    pub remote_transcription_model: Option<String>,
    pub backend: Option<SummarizerBackend>,
    pub assistant_model_id: Option<String>,
    pub autocomplete_model_id: Option<String>,
}

impl ModelPatch {
    pub fn apply(&self, settings: &mut Settings) {
        if let Some(id) = &self.transcription {
            settings.transcription_model = id.clone();
        }
        if let Some(url) = &self.remote_transcription_base_url {
            settings.remote_transcription_base_url = url.clone();
        }
        if let Some(model) = &self.remote_transcription_model {
            settings.remote_transcription_model = model.clone();
        }
        if let Some(backend) = self.backend {
            settings.summarizer_backend = backend;
        }
        if let Some(id) = &self.assistant_model_id {
            settings.built_in_model_id = id.clone();
        }
        if let Some(id) = &self.autocomplete_model_id {
            settings.cotyping_built_in_model_id = id.clone();
        }
    }

    fn applying(&self, settings: &Settings) -> Settings {
        let mut next = settings.clone();
        self.apply(&mut next);
        next
    }

    pub fn inverse(&self, settings: &Settings) -> Self {
        Self {
            transcription: self
                .transcription
                .as_ref()
                .map(|_| settings.transcription_model.clone()),
            remote_transcription_base_url: self
                .remote_transcription_base_url
                .as_ref()
                .map(|_| settings.remote_transcription_base_url.clone()),
            remote_transcription_model: self
                .remote_transcription_model
                .as_ref()
                .map(|_| settings.remote_transcription_model.clone()),
            backend: self.backend.map(|_| settings.summarizer_backend),
            assistant_model_id: self
                .assistant_model_id
                .as_ref()
                .map(|_| settings.built_in_model_id.clone()),
            autocomplete_model_id: self
                .autocomplete_model_id
                .as_ref()
                .map(|_| settings.cotyping_built_in_model_id.clone()),
        }
    }

    pub fn matches(&self, settings: &Settings) -> bool {
        self.inverse(settings) == *self
    }

    /// What has to be on this PC before the switch.
    pub fn needs(&self, settings: &Settings) -> Vec<String> {
        let target = self.applying(settings);
        let mut ids = Vec::new();
        if self.transcription.is_some() {
            if !lokalbot_speech::models::is_remote(&target.transcription_model) {
                ids.push(target.transcription_model.clone());
            }
            // Speech detection and speaker separation run here even with a server.
            ids.extend(lokalbot_speech::models::supporting_ids(
                target.multi_speaker_diarization,
            ));
        }
        if (self.backend.is_some() || self.assistant_model_id.is_some())
            && target.summarizer_backend == SummarizerBackend::BuiltIn
        {
            ids.push(target.built_in_model_id.clone());
            ids.push(RUNTIME_ID.to_string());
        }
        if let Some(id) = &self.autocomplete_model_id {
            ids.push(id.clone());
            ids.push(RUNTIME_ID.to_string());
        }
        let mut seen = HashSet::new();
        ids.retain(|id| seen.insert(id.clone()));
        ids
    }

    /// Why the target can't be used now: a transcription server or Think server
    /// that isn't approved. Checked again at the end, because an approval can be
    /// revoked while the replacement's downloads run.
    pub fn blocked_reason(&self, settings: &Settings) -> Option<String> {
        let target = self.applying(settings);
        if self.transcription.is_some()
            && lokalbot_speech::models::is_remote(&target.transcription_model)
            && let Err(error) = RemoteTranscription::from_settings(&target).validated_endpoint()
        {
            return Some(error.to_string());
        }
        if self.backend.is_some() {
            let approved = &target.approved_remote_inference_origins;
            match target.summarizer_backend {
                SummarizerBackend::OpenAICompatible => {
                    return remote_block_reason(&target.openai_base_url, approved);
                }
                SummarizerBackend::Ollama => {
                    return remote_block_reason(&target.ollama_base_url, approved);
                }
                SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => {
                    if let Some(plan) = SubscriptionPlan::for_backend(target.summarizer_backend)
                        && !plan.is_approved(&target)
                    {
                        return Some(lokalbot_i18n::format(
                            "Allow {0} under Manage Connections first.",
                            &[("0", lokalbot_i18n::tr(plan.title()).to_string())],
                        ));
                    }
                }
                SummarizerBackend::BuiltIn => {}
            }
        }
        None
    }

    /// Ids alone don't identify a custom model's files or a server. Activation
    /// is refused if either changed while the replacement was preparing.
    pub fn preparation_context_matches(&self, latest: &Settings, original: &Settings) -> bool {
        if original.custom_built_in_models != latest.custom_built_in_models {
            return false;
        }
        if self.backend.is_some() {
            match self.applying(original).summarizer_backend {
                SummarizerBackend::OpenAICompatible => {
                    return original.openai_base_url == latest.openai_base_url;
                }
                SummarizerBackend::Ollama => {
                    return original.ollama_base_url == latest.ollama_base_url;
                }
                _ => {}
            }
        }
        true
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub title: String,
    pub patch: ModelPatch,
    pub previous: ModelPatch,
}

struct Pending {
    change: Change,
    original: Settings,
    needs: Vec<String>,
}

/// One switch at a time, as long as the Settings page lives.
#[derive(Default)]
pub struct ModelSetup {
    pending: Option<Pending>,
    completed: Option<Change>,
    failure: Option<SharedString>,
    failed_change: Option<Change>,
}

impl ModelSetup {
    pub fn is_switching(&self) -> bool {
        self.pending.is_some()
    }

    /// The switch under way, for `lokalbot-cli models status`.
    pub fn pending_title(&self) -> Option<&str> {
        self.pending.as_ref().map(|p| p.change.title.as_str())
    }

    pub fn failure_message(&self) -> Option<&str> {
        self.failure.as_ref().map(|f| f.as_ref())
    }

    pub fn apply(
        &mut self,
        patch: ModelPatch,
        title: impl Into<String>,
        data: &Entity<AppData>,
        cx: &mut App,
    ) {
        self.pending = None;
        self.completed = None;
        self.failure = None;
        self.failed_change = None;
        let original = data.read(cx).settings.clone();
        let change = Change {
            title: title.into(),
            previous: patch.inverse(&original),
            patch,
        };
        if let Some(reason) = change.patch.blocked_reason(&original) {
            self.failure = Some(lokalbot_i18n::tr(&reason).to_string().into());
            self.failed_change = Some(change);
            return;
        }
        let needs = change.patch.needs(&original);
        data.update(cx, |data, cx| {
            // An earlier attempt's failure says nothing about this one.
            data.downloads
                .retain(|id, download| !(needs.contains(id) && download.error.is_some()));
            data.cancelled_downloads.clear();
            for id in &needs {
                if !data.models.installed.contains(id) && !data.downloads.contains_key(id) {
                    data.request(AppEvent::DownloadModel(id.clone()), cx);
                }
            }
        });
        self.pending = Some(Pending {
            change,
            original,
            needs,
        });
        self.poll(data, cx);
    }

    /// Follows the downloads; the switch happens once the last one lands.
    pub fn poll(&mut self, data: &Entity<AppData>, cx: &mut App) {
        let Some(pending) = &self.pending else {
            return;
        };
        let (failed, cancelled, ready, latest) = {
            let state = data.read(cx);
            (
                pending
                    .needs
                    .iter()
                    .find_map(|id| state.downloads.get(id).and_then(|d| d.error.clone())),
                pending
                    .needs
                    .iter()
                    .any(|id| state.cancelled_downloads.contains(id)),
                pending
                    .needs
                    .iter()
                    .all(|id| state.models.installed.contains(id)),
                state.settings.clone(),
            )
        };
        if cancelled {
            // Cancelling the download keeps the current selection.
            self.pending = None;
            return;
        }
        if let Some(error) = failed {
            let change = self.pending.take().map(|pending| pending.change);
            self.failure = Some(error);
            self.failed_change = change;
            return;
        }
        if !ready {
            return;
        }
        let Some(Pending {
            change, original, ..
        }) = self.pending.take()
        else {
            return;
        };
        let refusal = if !change.previous.matches(&latest) {
            Some(lokalbot_i18n::tr("The model selection changed while preparing. Your newer selection was kept. Choose the model again to switch.").to_string())
        } else if !change.patch.preparation_context_matches(&latest, &original) {
            Some(lokalbot_i18n::tr("The model files or connection changed while preparing. Your changes were kept. Choose the model again to switch.").to_string())
        } else {
            change
                .patch
                .blocked_reason(&latest)
                .map(|reason| lokalbot_i18n::tr(&reason).to_string())
        };
        if let Some(reason) = refusal {
            self.failure = Some(reason.into());
            self.failed_change = Some(change);
            return;
        }
        let patch = change.patch.clone();
        data.update(cx, |data, cx| {
            data.update_settings(move |settings| patch.apply(settings), cx)
        });
        self.completed = Some(change);
    }

    /// Keeps the current selection. Downloads already running continue.
    pub fn cancel(&mut self) {
        self.pending = None;
    }

    fn retry(&mut self, data: &Entity<AppData>, cx: &mut App) {
        if let Some(change) = self.failed_change.clone() {
            self.apply(change.patch, change.title, data, cx);
        }
    }

    /// Goes through the same preparation: the old files may have been removed
    /// since the switch.
    fn undo(&mut self, data: &Entity<AppData>, cx: &mut App) {
        let Some(completed) = self.completed.clone() else {
            return;
        };
        if !completed.patch.matches(&data.read(cx).settings) {
            self.completed = None;
            return;
        }
        self.apply(
            completed.previous,
            lokalbot_i18n::tr("Previous model setup"),
            data,
            cx,
        );
    }

    fn dismiss(&mut self) {
        self.completed = None;
        self.failure = None;
        self.failed_change = None;
    }
}

impl SettingsPage {
    /// The strip above the roles while a switch runs, failed or just finished
    /// (`ModelSetupFeedback`).
    pub(super) fn model_setup_feedback(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let setup = &self.models.setup;
        let page = cx.entity();
        let data = self.data.clone();
        let button =
            |id: &'static str, label: &'static str| Button::new(id).outline().small().label(label);
        let row = if let Some(pending) = &setup.pending {
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(
                    v_flex()
                        .flex_1()
                        .min_w_0()
                        .gap(px(2.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::MEDIUM)
                                .text_color(lb.text)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "Preparing {0}…",
                                    &[("0", pending.change.title.clone())],
                                ))),
                        )
                        .child(settings_row::help(
                            lokalbot_i18n::tr(
                                "Your current models stay active until preparation finishes.",
                            ),
                            cx,
                        )),
                )
                .child(
                    button(
                        "settings-model-switch-cancel",
                        lokalbot_i18n::tr("Cancel Switch"),
                    )
                    .tooltip(lokalbot_i18n::tr(
                        "Keep the current selection. Shared downloads continue.",
                    ))
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.models.setup.cancel();
                            cx.notify();
                        })
                    }),
                )
        } else if let Some(failure) = setup.failure.clone() {
            let retry = setup.failed_change.is_some().then(|| {
                let page = page.clone();
                let data = data.clone();
                button("settings-model-switch-retry", lokalbot_i18n::tr("Retry")).on_click(
                    move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.models.setup.retry(&data, cx);
                            cx.notify();
                        })
                    },
                )
            });
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(ui::icon(Ico::TriangleAlert, px(15.), lb.attention_text))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(failure)),
                )
                .children(retry)
                .child(
                    button(
                        "settings-model-switch-dismiss",
                        lokalbot_i18n::tr("Dismiss"),
                    )
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.models.setup.dismiss();
                            cx.notify();
                        })
                    }),
                )
        } else if let Some(completed) = &setup.completed {
            let undo_page = page.clone();
            h_flex()
                .gap(px(12.))
                .items_center()
                .child(ui::icon(Ico::CircleCheck, px(15.), lb.success_text))
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "Using {0}",
                            &[("0", completed.title.clone())],
                        ))),
                )
                .child(
                    button("settings-model-switch-undo", lokalbot_i18n::tr("Undo")).on_click(
                        move |_, _, cx| {
                            undo_page.update(cx, |page, cx| {
                                page.models.setup.undo(&data, cx);
                                cx.notify();
                            })
                        },
                    ),
                )
                .child(
                    button(
                        "settings-model-switch-dismiss",
                        lokalbot_i18n::tr("Dismiss"),
                    )
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| {
                            page.models.setup.dismiss();
                            cx.notify();
                        })
                    }),
                )
        } else {
            return None;
        };
        Some(settings_row::content_row("settings-model-switch", row, false, cx).into_any_element())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn think(id: &str) -> ModelPatch {
        ModelPatch {
            backend: Some(SummarizerBackend::BuiltIn),
            assistant_model_id: Some(id.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn a_patch_only_touches_what_it_names() {
        let settings = Settings::default();
        let mut changed = settings.clone();
        think("other").apply(&mut changed);
        assert_eq!(changed.built_in_model_id, "other");
        assert_eq!(changed.transcription_model, settings.transcription_model);
        assert_eq!(
            changed.cotyping_built_in_model_id,
            settings.cotyping_built_in_model_id
        );
    }

    #[test]
    fn the_inverse_restores_the_previous_values() {
        let settings = Settings {
            built_in_model_id: "old".into(),
            ..Default::default()
        };
        let patch = think("new");
        let inverse = patch.inverse(&settings);
        assert_eq!(inverse.assistant_model_id.as_deref(), Some("old"));
        assert_eq!(inverse.transcription, None);
        assert!(inverse.matches(&settings));
        assert!(!patch.matches(&settings));
        let mut after = settings.clone();
        patch.apply(&mut after);
        assert!(patch.matches(&after));
        inverse.apply(&mut after);
        assert_eq!(after, settings);
    }

    #[test]
    fn needs_list_only_what_the_target_uses() {
        let settings = Settings::default();
        assert_eq!(think("m").needs(&settings), ["m", RUNTIME_ID]);
        let server = ModelPatch {
            backend: Some(SummarizerBackend::Ollama),
            ..Default::default()
        };
        assert!(server.needs(&settings).is_empty());
        let transcribe = ModelPatch {
            transcription: Some("parakeet-v3".into()),
            ..Default::default()
        };
        let needs = transcribe.needs(&settings);
        assert_eq!(needs[0], "parakeet-v3");
        assert!(needs.contains(&lokalbot_speech::models::VAD_MODEL.to_string()));
        let remote = ModelPatch {
            transcription: Some(lokalbot_core::remote_transcription::MODEL_ID.into()),
            ..Default::default()
        };
        let needs = remote.needs(&settings);
        assert!(needs.contains(&lokalbot_speech::models::VAD_MODEL.to_string()));
        assert!(!needs.contains(&lokalbot_core::remote_transcription::MODEL_ID.to_string()));
        let autocomplete = ModelPatch {
            autocomplete_model_id: Some("a".into()),
            ..Default::default()
        };
        assert_eq!(autocomplete.needs(&settings), ["a", RUNTIME_ID]);
    }

    #[test]
    fn unapproved_servers_are_refused() {
        let mut settings = Settings {
            openai_base_url: "https://x.example/v1".into(),
            remote_transcription_base_url: "https://audio.example/v1".into(),
            ..Default::default()
        };
        let think_server = ModelPatch {
            backend: Some(SummarizerBackend::OpenAICompatible),
            ..Default::default()
        };
        assert!(think_server.blocked_reason(&settings).is_some());
        settings
            .approved_remote_inference_origins
            .push("https://x.example".into());
        assert_eq!(think_server.blocked_reason(&settings), None);

        let transcription = ModelPatch {
            transcription: Some(lokalbot_core::remote_transcription::MODEL_ID.into()),
            ..Default::default()
        };
        // A Think approval doesn't send audio.
        settings
            .approved_remote_inference_origins
            .push("https://audio.example".into());
        assert!(transcription.blocked_reason(&settings).is_some());
        settings
            .approved_remote_transcription_origins
            .push("https://audio.example".into());
        assert_eq!(transcription.blocked_reason(&settings), None);
    }

    #[test]
    fn a_changed_connection_or_custom_model_stops_the_switch() {
        let original = Settings {
            openai_base_url: "https://x.example/v1".into(),
            ..Default::default()
        };
        let patch = ModelPatch {
            backend: Some(SummarizerBackend::OpenAICompatible),
            ..Default::default()
        };
        let mut latest = original.clone();
        assert!(patch.preparation_context_matches(&latest, &original));
        latest.openai_base_url = "https://y.example/v1".into();
        assert!(!patch.preparation_context_matches(&latest, &original));
        assert!(think("m").preparation_context_matches(&latest, &original));
        latest.custom_built_in_models = vec![serde_json::json!({"id": "x"})];
        assert!(!think("m").preparation_context_matches(&latest, &original));
    }
}
