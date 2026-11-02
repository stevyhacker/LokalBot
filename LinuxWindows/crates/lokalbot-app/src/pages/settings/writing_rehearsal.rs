//! What the practice editor's last request drew on, and why it brought no
//! suggestion (`CotypingContextStatus.rehearsal`,
//! `AutocompleteExperienceView.explanation`): a working model that suggested
//! nothing shouldn't look like a broken one.

use gpui_kit::component::v_flex;
use gpui_kit::{App, Div, FontWeight, ParentElement as _, Styled as _, div, px};
use lokalbot_ai::autocomplete::Suppression;
use lokalbot_engine::AutocompleteRehearsal;

use super::writing::ContextState;
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico};

/// Why the model's answer isn't on screen.
pub(super) fn explanation(reason: Suppression) -> &'static str {
    match reason {
        Suppression::EmptyGeneration | Suppression::NormalizedToEmpty => {
            lokalbot_i18n::tr("The model answered with no text.")
        }
        Suppression::EchoesPrecedingText
        | Suppression::DuplicatesTrailingText
        | Suppression::PromptContextLeak => {
            lokalbot_i18n::tr("The model repeated text it was given, so its answer is hidden.")
        }
        Suppression::PlaceholderText
        | Suppression::QuestionContinuation
        | Suppression::UnsafeToInsert
        | Suppression::WordCompletionMismatch => {
            lokalbot_i18n::tr("The answer did not fit at the cursor, so it is hidden.")
        }
        Suppression::LowConfidence => {
            lokalbot_i18n::tr("The model was unsure of the next word, so it suggested nothing.")
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Tone {
    /// The source shaped this suggestion.
    Used,
    /// On and working; it had nothing to add this time.
    Ready,
    /// On but can't contribute.
    Attention,
    Off,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Status {
    pub title: &'static str,
    pub detail: String,
    pub tone: Tone,
}

/// The three optional sources, in the order Settings lists them. `used` is `None`
/// until the practice editor has asked for a suggestion.
pub(super) fn statuses(
    visible: &ContextState,
    meetings: &ContextState,
    screen: &ContextState,
    used: Option<&AutocompleteRehearsal>,
) -> Vec<Status> {
    vec![
        visible_text(visible, used),
        memory(
            lokalbot_i18n::tr("Meeting and work memory"),
            meetings,
            used.map(|used| used.meeting_sources.as_slice()),
            used,
        ),
        memory(
            lokalbot_i18n::tr("Screen-derived work memory"),
            screen,
            used.map(|used| used.screen_sources.as_slice()),
            used,
        ),
    ]
}

fn visible_text(state: &ContextState, used: Option<&AutocompleteRehearsal>) -> Status {
    let title = lokalbot_i18n::tr("Visible text above the field");
    let read = used.is_some_and(|used| used.visible_text);
    let here = lokalbot_i18n::tr("Used the sample conversation above.");
    let (detail, tone) = match state {
        ContextState::Off => (lokalbot_i18n::tr("Off").to_string(), Tone::Off),
        ContextState::Available(_) | ContextState::NothingSaved(_) if read => {
            (here.to_string(), Tone::Used)
        }
        ContextState::Available(_) | ContextState::NothingSaved(_) => (
            lokalbot_i18n::tr("On. The sample conversation above stands in for nearby text.")
                .to_string(),
            Tone::Ready,
        ),
        // The practice editor still reads its own sample, so it says both.
        ContextState::Unavailable(reason) => {
            let elsewhere =
                lokalbot_i18n::format("In other apps: {0}", &[("0", reason.to_string())]);
            (
                if read {
                    format!("{here} {elsewhere}")
                } else {
                    elsewhere
                },
                Tone::Attention,
            )
        }
    };
    Status {
        title,
        detail,
        tone,
    }
}

fn memory(
    title: &'static str,
    state: &ContextState,
    sources: Option<&[String]>,
    used: Option<&AutocompleteRehearsal>,
) -> Status {
    let (detail, tone) = match state {
        ContextState::Off => (lokalbot_i18n::tr("Off").to_string(), Tone::Off),
        ContextState::Unavailable(reason) | ContextState::NothingSaved(reason) => {
            (reason.clone(), Tone::Attention)
        }
        ContextState::Available(detail) => match sources {
            Some(sources) if !sources.is_empty() => (
                lokalbot_i18n::format("Used: {0}", &[("0", sources.join(", "))]),
                Tone::Used,
            ),
            _ if used.is_some_and(|used| used.searched_memory) => (
                lokalbot_i18n::tr("No relevant memory found.").to_string(),
                Tone::Ready,
            ),
            _ => (detail.clone(), Tone::Ready),
        },
    };
    Status {
        title,
        detail,
        tone,
    }
}

/// "Context for this suggestion", with sources and states in columns.
pub(super) fn render(statuses: &[Status], cx: &App) -> Div {
    let lb = cx.lb();
    v_flex()
        .gap(px(6.))
        .pt(px(2.))
        .child(
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                    "Context for this suggestion",
                ))),
        )
        .children(statuses.iter().map(|status| {
            let dot = match status.tone {
                Tone::Used => lb.success_text,
                Tone::Attention => lb.attention_text,
                Tone::Ready | Tone::Off => lb.text_secondary,
            };
            h_flex()
                .gap(px(8.))
                .items_start()
                .text_size(ty::SECONDARY)
                .child(
                    div()
                        .mt(px(6.))
                        .size(px(7.))
                        .flex_none()
                        .rounded_full()
                        .bg(dot),
                )
                .child(
                    div()
                        .flex_none()
                        .w(px(200.))
                        .text_color(if status.tone == Tone::Off {
                            lb.text_secondary
                        } else {
                            lb.text
                        })
                        .child(status.title),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .text_color(if status.tone == Tone::Attention {
                            lb.attention_text
                        } else {
                            lb.text_secondary
                        })
                        .child(status.detail.clone()),
                )
        }))
}

/// The note under the practice editor when the model answered with nothing to
/// show.
pub(super) fn explanation_line(reason: Suppression, cx: &App) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(8.))
        .items_start()
        .text_size(ty::SECONDARY)
        .text_color(lb.text_secondary)
        .child(
            div()
                .pt(px(1.))
                .child(ui::icon(Ico::Info, px(14.), lb.text_secondary)),
        )
        .child(
            div()
                .flex_1()
                .min_w_0()
                .child(crate::ui::text::paragraph(explanation(reason))),
        )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn available() -> ContextState {
        ContextState::Available("Saved: 2 meetings".into())
    }

    #[test]
    fn before_a_suggestion_each_source_says_only_if_it_is_on() {
        let statuses = statuses(&available(), &ContextState::Off, &available(), None);
        assert_eq!(statuses[0].tone, Tone::Ready);
        assert!(statuses[0].detail.starts_with("On."));
        assert_eq!(statuses[1].tone, Tone::Off);
        assert_eq!(statuses[1].detail, "Off");
        assert_eq!(statuses[2].tone, Tone::Ready);
        assert_eq!(statuses[2].detail, "Saved: 2 meetings");
    }

    #[test]
    fn after_a_suggestion_each_source_says_what_it_gave() {
        let used = AutocompleteRehearsal {
            suppression: None,
            visible_text: true,
            meeting_sources: vec!["Design review".into(), "Standup".into()],
            screen_sources: Vec::new(),
            searched_memory: true,
        };
        let statuses = statuses(&available(), &available(), &available(), Some(&used));
        assert_eq!(statuses[0].tone, Tone::Used);
        assert_eq!(statuses[1].tone, Tone::Used);
        assert_eq!(statuses[1].detail, "Used: Design review, Standup");
        assert_eq!(statuses[2].tone, Tone::Ready);
        assert_eq!(statuses[2].detail, "No relevant memory found.");
    }

    #[test]
    fn a_source_that_cant_contribute_says_why() {
        let blocked = ContextState::Unavailable("Unavailable: autocomplete is off.".into());
        let used = AutocompleteRehearsal {
            visible_text: true,
            ..Default::default()
        };
        let statuses = statuses(
            &blocked,
            &ContextState::NothingSaved("Nothing to use yet.".into()),
            &blocked,
            Some(&used),
        );
        assert_eq!(statuses[0].tone, Tone::Attention);
        assert_eq!(
            statuses[0].detail,
            "Used the sample conversation above. In other apps: Unavailable: autocomplete is off."
        );
        assert_eq!(statuses[1].detail, "Nothing to use yet.");
        assert_eq!(statuses[2].tone, Tone::Attention);
    }

    #[test]
    fn every_empty_answer_has_a_reason() {
        for (reason, says) in [
            (Suppression::EmptyGeneration, "no text"),
            (Suppression::NormalizedToEmpty, "no text"),
            (Suppression::EchoesPrecedingText, "repeated"),
            (Suppression::DuplicatesTrailingText, "repeated"),
            (Suppression::PromptContextLeak, "repeated"),
            (Suppression::PlaceholderText, "did not fit"),
            (Suppression::QuestionContinuation, "did not fit"),
            (Suppression::UnsafeToInsert, "did not fit"),
            (Suppression::WordCompletionMismatch, "did not fit"),
            (Suppression::LowConfidence, "unsure"),
        ] {
            assert!(explanation(reason).contains(says), "{reason:?}");
        }
    }
}
