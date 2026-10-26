//! Suggested names in Name Speaker (`MeetingSpeakerRenameSheet`): the
//! meeting's calendar guests and name hints. Choosing a guest keeps its
//! opaque identity with the name (`speakerCalendarIdentityIDs`), so same-named
//! guests stay apart; attendance alone never names a voice. Typing in the
//! name input searches the suggestions.

use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;

use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    Pixels, SharedString, StatefulInteractiveElement as _, Styled as _, canvas, div, px,
};
use lokalbot_core::calendar::{SpeakerSuggestion, SuggestionSource};
use lokalbot_core::{Meeting, Transcript};

use super::dialogs::NameSpeakerSheet;
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

const LIST_MAX_HEIGHT: f32 = 220.;

pub(crate) struct SpeakerSuggestions {
    pub choices: Vec<SpeakerSuggestion>,
    /// The calendar guest chosen for this voice.
    pub selected: Option<String>,
    /// Guests already given to another voice in this meeting.
    assigned_elsewhere: HashSet<String>,
    /// The name as last typed, which searches the suggestions. A choice
    /// clears it, so the whole list shows again.
    pub query: String,
    /// The tallest the list has been, so filtering never shrinks the sheet.
    list_height: Rc<Cell<Pixels>>,
}

impl SpeakerSuggestions {
    pub fn new(meeting: &Meeting, transcript: &Transcript, speaker_key: &str) -> Self {
        let guests = lokalbot_core::calendar::resolved_meeting_identities(meeting);
        let hints = meeting.participant_name_hints.clone().unwrap_or_default();
        let choices = SpeakerSuggestion::choices(&guests, &hints);
        let selected = transcript
            .speaker_calendar_identity_ids
            .get(speaker_key)
            .cloned();
        let assigned_elsewhere = transcript
            .speaker_calendar_identity_ids
            .iter()
            .filter(|(key, _)| key.as_str() != speaker_key)
            .map(|(_, id)| id.clone())
            .collect();
        Self {
            choices,
            selected,
            assigned_elsewhere,
            query: String::new(),
            list_height: Rc::new(Cell::new(px(0.))),
        }
    }

    /// The calendar identity to save with `name`: the chosen guest's, while
    /// a guest is chosen.
    pub fn identity_for_save(&self) -> Option<String> {
        self.selected.clone()
    }

    fn is_chosen(&self, choice: &SpeakerSuggestion, name: &str) -> bool {
        match &self.selected {
            Some(id) => choice
                .calendar
                .as_ref()
                .is_some_and(|guest| &guest.id == id),
            None => {
                choice.calendar.is_none()
                    && choice.name.as_deref().map(SpeakerSuggestion::name_key)
                        == Some(SpeakerSuggestion::name_key(name))
            }
        }
    }

    /// Matches for the typed name. The chosen guest stays listed while its
    /// name is edited, since saving keeps that guest.
    fn visible(&self, name: &str) -> Vec<usize> {
        let query = self.query.trim();
        (0..self.choices.len())
            .filter(|&index| {
                let choice = &self.choices[index];
                query.is_empty() || choice.matches(query) || self.is_chosen(choice, name)
            })
            .collect()
    }

    /// The top match not already chosen, which Enter fills in. With none,
    /// Enter saves the name as typed.
    pub fn return_choice(&self, name: &str) -> Option<usize> {
        let query = self.query.trim();
        if query.is_empty() {
            return None;
        }
        (0..self.choices.len()).find(|&index| {
            let choice = &self.choices[index];
            choice.matches(query) && !self.is_chosen(choice, name)
        })
    }

    pub fn render(&self, name: &str, cx: &mut Context<NameSpeakerSheet>) -> Option<AnyElement> {
        if self.choices.is_empty() {
            return None;
        }
        let lb = cx.lb().clone();
        let visible = self.visible(name);
        let return_choice = self.return_choice(name);
        let height = self.list_height.clone();
        let measure = canvas(
            move |bounds, window, _| {
                if bounds.size.height > height.get() {
                    height.set(bounds.size.height);
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        let mut list = v_flex().relative().gap(px(6.)).child(measure);
        for &index in &visible {
            let choice = &self.choices[index];
            list = list.child(self.row(index, choice, name, return_choice == Some(index), cx));
        }
        if visible.is_empty() {
            list = list.child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr("No suggested names match this search.")),
            );
        }
        let max_height = px(LIST_MAX_HEIGHT);
        let min_height = if self.list_height.get() > max_height {
            max_height
        } else {
            self.list_height.get()
        };
        Some(
            v_flex()
                .gap(px(8.))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text)
                        .child(lokalbot_i18n::tr("Suggested Names")),
                )
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Listen, choose a name, then save. These sources suggest names; attendance does not identify a voice."))),
                )
                .child(
                    div()
                        .id("speaker-suggestions")
                        .min_h(min_height)
                        .max_h(max_height)
                        .overflow_y_scroll()
                        .child(list),
                )
                .when(self.choices.iter().any(|c| c.calendar.is_some()), |this| {
                    this.child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Email addresses stay in this meeting's local metadata and help distinguish guests."))),
                    )
                })
                .into_any_element(),
        )
    }

    fn row(
        &self,
        index: usize,
        choice: &SpeakerSuggestion,
        name: &str,
        is_return_choice: bool,
        cx: &mut Context<NameSpeakerSheet>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let selected = self.is_chosen(choice, name);
        let elsewhere = choice
            .calendar
            .as_ref()
            .is_some_and(|guest| self.assigned_elsewhere.contains(&guest.id));
        let title: SharedString = match &choice.name {
            Some(name) => name.clone().into(),
            None => lokalbot_i18n::tr("Enter a name for this guest").into(),
        };
        let badges = choice.sources().into_iter().map(|source| {
            let label = match source {
                SuggestionSource::Calendar => lokalbot_i18n::tr("Calendar"),
                SuggestionSource::NameFromEmail => lokalbot_i18n::tr("Name from email"),
                SuggestionSource::SuggestedName => lokalbot_i18n::tr("Suggested name"),
            };
            div()
                .px(px(6.))
                .py(px(1.))
                .rounded(px(5.))
                .bg(lb.accent_fill.opacity(0.14))
                .text_size(ty::CAPTION)
                .text_color(lb.accent_text)
                .child(label)
        });
        div()
            .id(SharedString::from(format!("speaker-suggestion-{index}")))
            .cursor_pointer()
            .p(px(10.))
            .rounded(px(9.))
            .border_1()
            .border_color(if selected {
                lb.accent_text.opacity(0.6)
            } else {
                lb.group_stroke
            })
            .bg(if selected {
                lb.accent_fill.opacity(0.10)
            } else {
                lb.group_fill
            })
            .child(
                v_flex()
                    .gap(px(4.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(ui::icon(
                                if selected {
                                    Ico::CircleCheckBig
                                } else {
                                    Ico::User
                                },
                                px(15.),
                                if selected {
                                    lb.accent_text
                                } else {
                                    lb.text_secondary
                                },
                            ))
                            .child(
                                div()
                                    .flex_1()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .when(is_return_choice, |this| {
                                this.child(ui::icon(
                                    Ico::CornerDownLeft,
                                    px(13.),
                                    lb.text_secondary,
                                ))
                            }),
                    )
                    .child(h_flex().gap(px(6.)).flex_wrap().children(badges))
                    .when_some(
                        choice
                            .calendar
                            .as_ref()
                            .and_then(|g| g.email_address.clone()),
                        |this, email| {
                            this.child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(email),
                            )
                        },
                    )
                    .when(elsewhere, |this| {
                        this.child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(lokalbot_i18n::tr("Also assigned to another voice")),
                        )
                    }),
            )
            .on_click(
                cx.listener(move |sheet, _, window, cx| sheet.choose_suggestion(index, window, cx)),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lokalbot_core::CalendarParticipantIdentity;

    fn suggestions(selected: Option<&str>) -> SpeakerSuggestions {
        let guests = [
            CalendarParticipantIdentity::new("ana", Some("Ana"), Some("ana.petrovic@example.com"))
                .unwrap(),
            CalendarParticipantIdentity::new("marko", Some("Marko Marković"), None).unwrap(),
        ];
        SpeakerSuggestions {
            choices: SpeakerSuggestion::choices(&guests, &["Matt".to_string()]),
            selected: selected.map(str::to_string),
            assigned_elsewhere: HashSet::new(),
            query: String::new(),
            list_height: Rc::new(Cell::new(px(0.))),
        }
    }

    #[test]
    fn typing_filters_and_enter_fills_in_the_top_match() {
        let mut list = suggestions(None);
        assert_eq!(
            list.visible("Ana"),
            [0, 1, 2],
            "an untyped name shows every suggestion"
        );
        assert_eq!(list.return_choice("Ana"), None);

        list.query = "mark".into();
        assert_eq!(list.visible("mark"), [1]);
        assert_eq!(list.return_choice("mark"), Some(1));
    }

    #[test]
    fn enter_saves_when_nothing_new_matches() {
        let mut list = suggestions(None);
        list.query = "Hernan".into();
        assert!(list.visible("Hernan").is_empty());
        assert_eq!(list.return_choice("Hernan"), None);

        // A typed hint name is already that suggestion, so Enter saves it.
        list.query = "matt".into();
        assert_eq!(list.return_choice("matt"), None);
    }

    #[test]
    fn the_chosen_guest_stays_listed_while_its_name_is_edited() {
        let mut list = suggestions(Some("ana"));
        list.query = "Ana Petrović".into();
        assert_eq!(list.visible("Ana Petrović"), [0]);
        assert_eq!(
            list.return_choice("Ana Petrović"),
            None,
            "Enter saves the longer name instead of filling in \"Ana\" again"
        );

        list.query = "Matt".into();
        assert_eq!(list.visible("Matt"), [0, 2]);
        assert_eq!(list.return_choice("Matt"), Some(2));
    }
}
