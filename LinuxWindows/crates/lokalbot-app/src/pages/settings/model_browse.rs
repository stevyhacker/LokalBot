//! Add a model from Hugging Face (`ModelImportSheet`). Adding only edits
//! `customBuiltInModels`; the model then appears in Think's and Autocomplete's
//! choices, and downloads when chosen. Search goes to huggingface.co whichever
//! download source is chosen.

use crate::i18n::h_flex;
use gpui_kit::component::button::Button;
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Sizable as _, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement as _, ParentElement as _, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, px,
};
use lokalbot_ai::hugging_face::{self, HfFile, ModelSummary};
use serde_json::Value;

use super::model_options::subpage_header;
use super::models::size_label;
use super::{Section, SettingsPage};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::settings_row;

pub struct BrowseState {
    query: Entity<InputState>,
    results: Vec<ModelSummary>,
    searching: bool,
    /// Bumped by each search, so a newer one wins.
    generation: u64,
    error: Option<SharedString>,
    selected: Option<String>,
    files: Vec<HfFile>,
    loading_files: bool,
}

impl BrowseState {
    pub fn new(window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        Self {
            query: cx.new(|cx| {
                InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                    "Search downloadable models (e.g. Qwen, Llama)…",
                    window,
                    cx,
                ))
            }),
            results: Vec::new(),
            searching: false,
            generation: 0,
            error: None,
            selected: None,
            files: Vec::new(),
            loading_files: false,
        }
    }

    pub fn subscribe(
        &self,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        vec![cx.subscribe_in(
            &self.query,
            window,
            |page, _, event: &InputEvent, _, cx| match event {
                InputEvent::PressEnter { .. } => page.search_models(cx),
                InputEvent::Change => cx.notify(),
                _ => {}
            },
        )]
    }
}

/// `customBuiltInModels` with `record` replacing any entry with its id.
fn with_added(records: &[Value], record: Value) -> Vec<Value> {
    let mut next: Vec<Value> = records
        .iter()
        .filter(|existing| existing.get("id") != record.get("id"))
        .cloned()
        .collect();
    next.push(record);
    next
}

fn without(records: &[Value], id: &str) -> Vec<Value> {
    records
        .iter()
        .filter(|record| record.get("id").and_then(Value::as_str) != Some(id))
        .cloned()
        .collect()
}

impl SettingsPage {
    fn search_models(&mut self, cx: &mut Context<Self>) {
        let query = self.models.browse.query.read(cx).value().trim().to_string();
        let browse = &mut self.models.browse;
        browse.generation += 1;
        browse.selected = None;
        browse.files.clear();
        browse.error = None;
        if query.is_empty() {
            browse.results.clear();
            browse.searching = false;
            cx.notify();
            return;
        }
        browse.searching = true;
        let generation = browse.generation;
        cx.notify();
        cx.spawn(async move |page, cx| {
            let found = cx
                .background_spawn(async move { hugging_face::search_models(&query) })
                .await;
            let _ = page.update(cx, |page, cx| {
                let browse = &mut page.models.browse;
                if browse.generation != generation {
                    return;
                }
                browse.searching = false;
                match found {
                    Ok(found) => browse.results = found,
                    Err(error) => {
                        browse.results.clear();
                        browse.error =
                            Some(lokalbot_i18n::tr(&error.to_string()).to_string().into());
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn open_repository(&mut self, id: String, cx: &mut Context<Self>) {
        let browse = &mut self.models.browse;
        if browse.selected.as_deref() == Some(id.as_str()) {
            browse.selected = None;
            browse.files.clear();
            cx.notify();
            return;
        }
        browse.selected = Some(id.clone());
        browse.files.clear();
        browse.loading_files = true;
        browse.error = None;
        cx.notify();
        let model_id = id.clone();
        cx.spawn(async move |page, cx| {
            let listed = cx
                .background_spawn(async move { hugging_face::files(&model_id) })
                .await;
            let _ = page.update(cx, |page, cx| {
                let browse = &mut page.models.browse;
                if browse.selected.as_deref() != Some(id.as_str()) {
                    return;
                }
                browse.loading_files = false;
                match listed {
                    Ok(files) => browse.files = files,
                    Err(error) => {
                        browse.error =
                            Some(lokalbot_i18n::tr(&error.to_string()).to_string().into())
                    }
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn add_model(&mut self, file: &HfFile, cx: &mut Context<Self>) {
        let record = file.catalog_record();
        let name = file.file_name();
        self.update_settings(
            move |s| s.custom_built_in_models = with_added(&s.custom_built_in_models, record),
            cx,
        );
        let settings = self.data.read(cx).settings.clone();
        lokalbot_ai::catalog::set_custom(&settings.custom_built_in_models);
        self.data.update(cx, |data, cx| {
            data.show_message(
                lokalbot_i18n::format(
                    "{0} added. Choose it under Change… for Think or Autocomplete.",
                    &[("0", name)],
                ),
                cx,
            )
        });
        cx.notify();
    }

    pub(super) fn model_browse_page(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let lb = cx.lb().clone();
        let header = subpage_header(
            cx.entity(),
            lokalbot_i18n::tr("Add a model from Hugging Face"),
            lokalbot_i18n::tr(
                "Search GGUF repositories, then add a file. Adding a model doesn't download it.",
            ),
            cx,
        );
        let page = cx.entity();
        let browse = &self.models.browse;
        let has_query = !browse.query.read(cx).value().trim().is_empty();
        let search_row = h_flex()
            .gap(px(8.))
            .items_center()
            .child(div().flex_1().min_w_0().child(Input::new(&browse.query)))
            .child(
                Button::new("settings-browse-search")
                    .outline()
                    .small()
                    .label(if browse.searching {
                        lokalbot_i18n::tr("Searching…")
                    } else {
                        lokalbot_i18n::tr("Search")
                    })
                    .disabled(!has_query || browse.searching)
                    .on_click(move |_, _, cx| page.update(cx, |page, cx| page.search_models(cx))),
            );
        let error = browse.error.clone();
        let mut results = v_flex().gap(px(8.)).child(search_row);
        if let Some(message) = error {
            results = results.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.attention_text)
                    .child(crate::ui::text::paragraph(message)),
            );
        }
        for (index, model) in browse.results.iter().enumerate() {
            let open_page = cx.entity();
            let id = model.id.clone();
            let selected = browse.selected.as_deref() == Some(model.id.as_str());
            results = results.child(
                v_flex()
                    .id(("settings-browse-repository", index))
                    .cursor_pointer()
                    .gap(px(1.))
                    .child(
                        div()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(model.id.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(format!("↓ {}   ♥ {}", model.downloads, model.likes)),
                    )
                    .on_click(move |_, _, cx| {
                        open_page.update(cx, |page, cx| page.open_repository(id.clone(), cx))
                    }),
            );
            if selected {
                results = results.child(self.browse_files(cx));
            }
        }
        let mut sections = vec![
            Section::new(None).row(
                "settings.modelsHeader",
                settings_row::content_row("settings.modelsHeader", header, false, cx),
            ),
            Section::new(None).row(
                "settings.modelBrowse",
                settings_row::content_row("settings.modelBrowse", results, false, cx),
            ),
        ];
        if let Some(added) = self.added_models_section(cx) {
            sections.push(added);
        }
        sections
    }

    fn browse_files(&self, cx: &mut Context<Self>) -> AnyElement {
        let browse = &self.models.browse;
        if browse.loading_files {
            return settings_row::help(lokalbot_i18n::tr("Loading…"), cx)
                .pl(px(16.))
                .into_any_element();
        }
        if browse.files.is_empty() {
            return settings_row::help(
                lokalbot_i18n::tr("No compatible model files in this repository."),
                cx,
            )
            .pl(px(16.))
            .into_any_element();
        }
        let lb = cx.lb().clone();
        let mut list = v_flex().gap(px(6.)).pl(px(16.));
        for (index, file) in browse.files.iter().enumerate() {
            let page = cx.entity();
            let to_add = file.clone();
            list = list.child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .truncate()
                            .child(file.id.clone()),
                    )
                    .children(file.size_bytes.map(|size| {
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(size_label(size))
                    }))
                    .child(
                        Button::new(("settings-browse-add", index))
                            .outline()
                            .xsmall()
                            .label(lokalbot_i18n::tr("Add model"))
                            .on_click(move |_, _, cx| {
                                page.update(cx, |page, cx| page.add_model(&to_add, cx))
                            }),
                    ),
            );
        }
        list.into_any_element()
    }

    /// Models added so far, with Remove from List once nothing depends on them.
    fn added_models_section(&mut self, cx: &mut Context<Self>) -> Option<Section> {
        let lb = cx.lb().clone();
        let (settings, installed) = {
            let data = self.data.read(cx);
            (data.settings.clone(), data.models.installed.clone())
        };
        let added = lokalbot_ai::catalog::custom_entries();
        if added.is_empty() {
            return None;
        }
        let mut column = v_flex().gap(px(10.));
        for (index, entry) in added.into_iter().enumerate() {
            let downloaded = installed.iter().any(|id| id == entry.id);
            let blocker =
                lokalbot_ai::catalog::custom_removal_blocker(entry.id, &settings, downloaded);
            let page = cx.entity();
            let id = entry.id;
            column = column.child(
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
                                    .text_color(lb.text)
                                    .truncate()
                                    .child(entry.display_name),
                            )
                            .child(settings_row::help(
                                match &blocker {
                                    Some(reason) => lokalbot_i18n::tr(reason).to_string(),
                                    None => entry.blurb.to_string(),
                                },
                                cx,
                            )),
                    )
                    .child(
                        Button::new(("settings-browse-remove", index))
                            .outline()
                            .small()
                            .label(lokalbot_i18n::tr("Remove from List"))
                            .disabled(blocker.is_some())
                            .on_click(move |_, _, cx| {
                                page.update(cx, |page, cx| {
                                    page.update_settings(
                                        move |s| {
                                            s.custom_built_in_models =
                                                without(&s.custom_built_in_models, id)
                                        },
                                        cx,
                                    );
                                    let settings = page.data.read(cx).settings.clone();
                                    lokalbot_ai::catalog::set_custom(
                                        &settings.custom_built_in_models,
                                    );
                                    cx.notify();
                                })
                            }),
                    ),
            );
        }
        Some(Section::new(lokalbot_i18n::tr("Added models")).row(
            "settings.customModels",
            settings_row::content_row("settings.customModels", column, false, cx),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn adding_replaces_an_entry_with_the_same_id_and_keeps_unknown_keys() {
        let records = vec![
            json!({"id": "a", "extra": 1}),
            json!({"id": "b", "displayName": "old"}),
        ];
        let next = with_added(&records, json!({"id": "b", "displayName": "new"}));
        assert_eq!(next.len(), 2);
        assert_eq!(next[0]["extra"], 1);
        assert_eq!(next[1]["displayName"], "new");
        let removed = without(&next, "a");
        assert_eq!(removed.len(), 1);
        assert_eq!(removed[0]["id"], "b");
    }

    /// Both apps read the record: what's added here parses as a catalog entry.
    #[test]
    fn an_added_file_becomes_a_usable_model() {
        let digest = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
        let file = HfFile {
            id: "m-Q4.gguf".to_string(),
            model_id: "owner/repo".to_string(),
            size_bytes: Some(1_000),
            revision: "0123456789abcdef0123456789abcdef01234567".to_string(),
            sha256: Some(digest.to_string()),
        };
        lokalbot_ai::catalog::set_custom(&[file.catalog_record()]);
        let entry = lokalbot_ai::catalog::entry("hf:owner/repo/m-Q4.gguf").unwrap();
        assert_eq!(entry.size_bytes, 1_000);
        assert_eq!(entry.sha256, digest);
        assert_eq!(entry.file, file.file_name());
        lokalbot_ai::catalog::set_custom(&[]);
    }
}
