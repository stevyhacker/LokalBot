//! The conversation list (`ChatConversationList`).

use chrono::{DateTime, Days, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariant};

use crate::i18n::h_flex;
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{ContextMenuExt as _, PopupMenuItem};
use gpui_kit::component::{Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    StatefulInteractiveElement as _, Styled as _, Window, div, px,
};
use lokalbot_core::{ChatRole, Conversation};

use super::AskPage;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

pub const NEW_TITLE: &str = "New conversation";

impl AskPage {
    pub(super) fn render_history(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let count = self.conversations.len();
        let sections = sections(&self.conversations, &self.history_query, Local::now());
        let query = self.history_query.trim().to_string();

        let header =
            v_flex()
                .gap(px(8.))
                .px(px(10.))
                .pt(px(14.))
                .pb(px(10.))
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::COLUMN_TITLE)
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                            "Conversations",
                                        ))),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.supporting)
                                        .child(count_label(count, "conversation")),
                                ),
                        )
                        .child(
                            Button::new("ask-new-conversation")
                                .outline()
                                .small()
                                .icon(Icon::new(Ico::SquarePen))
                                .tooltip(lokalbot_i18n::tr("Start a new question (Ctrl+N)"))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.new_conversation(window, cx)
                                })),
                        ),
                )
                .child(
                    Input::new(&self.history_input)
                        .cleanable(true)
                        .prefix(ui::icon(Ico::Search, px(14.), lb.text_secondary)),
                );

        let mut rows: Vec<AnyElement> = Vec::new();
        if sections.is_empty() {
            let message = if query.is_empty() {
                if self.conversations_loaded {
                    lokalbot_i18n::tr("Questions you ask appear here.").to_string()
                } else {
                    String::new()
                }
            } else {
                lokalbot_i18n::format(
                    "No questions match “{query}”.",
                    &[("query", query.to_string())],
                )
            };
            rows.push(
                div()
                    .px(px(18.))
                    .py(px(6.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(message)
                    .into_any_element(),
            );
        }
        for (title, conversations) in sections {
            rows.push(
                div()
                    .px(px(18.))
                    .pt(px(10.))
                    .pb(px(4.))
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(title)
                    .into_any_element(),
            );
            for conversation in conversations {
                rows.push(self.render_history_row(conversation, cx).into_any_element());
            }
        }

        v_flex()
            .w(metric::CONTENT_COLUMN_WIDTH)
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
            .child(header)
            .child(
                div()
                    .id("ask-history")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.history_scroll)
                    .pb(px(12.))
                    .children(rows),
            )
    }

    fn render_history_row(
        &self,
        conversation: &Conversation,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let id = conversation.id;
        let selected = self.selected == Some(id);
        let title = display_title(conversation);
        let stamp = row_timestamp(conversation.updated_at, Local::now());
        let page = cx.entity();
        let menu_title = title.clone();
        div()
            .id(("ask-conversation", element_key(id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(6.))
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|style| style.bg(lb.hover)))
            .child(
                v_flex()
                    .gap(px(2.))
                    .min_w_0()
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(title),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(stamp),
                    ),
            )
            .on_click(
                cx.listener(move |this, _, window, cx| this.select_conversation(id, window, cx)),
            )
            .context_menu(move |menu, _, _| {
                let page = page.clone();
                let title = menu_title.clone();
                menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Delete"))
                        .icon(Icon::new(Ico::Trash))
                        .on_click(move |_, window, cx| {
                            confirm_delete(page.clone(), id, title.clone(), window, cx);
                        }),
                )
            })
    }
}

fn confirm_delete(
    page: gpui_kit::Entity<AskPage>,
    id: uuid::Uuid,
    title: String,
    window: &mut Window,
    cx: &mut gpui_kit::App,
) {
    window.open_alert_dialog(cx, move |alert, _, _| {
        let page = page.clone();
        alert
            .title(lokalbot_i18n::tr("Delete Question?"))
            .description(lokalbot_i18n::format(
                "This removes “{title}” from Ask history.",
                &[("title", title.to_string())],
            ))
            .confirm()
            .ok_text(lokalbot_i18n::tr("Delete"))
            .ok_variant(ButtonVariant::Danger)
            .cancel_text(lokalbot_i18n::tr("Cancel"))
            .on_ok(move |_, _, cx| {
                page.update(cx, |page, cx| page.delete_conversation(id, cx));
                true
            })
    });
}

/// A 64-bit key for element ids derived from a UUID.
pub fn element_key(id: uuid::Uuid) -> u64 {
    let (high, low) = id.as_u64_pair();
    high ^ low
}

/// "N conversations" / "1 conversation".
pub fn count_label(count: usize, noun: &str) -> String {
    lokalbot_i18n::count(count, noun)
}

/// The list title (`ChatViewModel.displayTitle`).
pub fn display_title(conversation: &Conversation) -> String {
    let stored = conversation.title.trim();
    if stored == NEW_TITLE {
        return lokalbot_i18n::tr(NEW_TITLE).into();
    }
    let source = if stored.ends_with('…') || stored.is_empty() {
        conversation
            .messages
            .iter()
            .find(|m| m.role == ChatRole::User)
            .map(|m| m.text.as_str())
            .unwrap_or(stored)
    } else {
        stored
    };
    compact_title(source)
}

/// `ChatViewModel.compactTitle`: first line, polite prefixes dropped, ≤ 38 characters.
pub fn compact_title(text: &str) -> String {
    let line = text.lines().next().unwrap_or(text);
    let mut candidate = line.split_whitespace().collect::<Vec<_>>().join(" ");
    if candidate.is_empty() {
        return NEW_TITLE.into();
    }
    if let Some(colon) = candidate.find(':') {
        let lead = candidate[..colon].to_lowercase();
        if lead.contains("task title") || lead.contains("for this task") {
            candidate = candidate[colon + 1..].trim().to_string();
        }
    }
    for prefix in [
        "please give me ",
        "give me ",
        "please tell me ",
        "tell me ",
        "please ",
    ] {
        if candidate.to_lowercase().starts_with(prefix) {
            candidate = candidate[prefix.len()..].to_string();
            break;
        }
    }
    if let Some(comma) = candidate.find(',')
        && candidate[..comma].chars().count() >= 18
    {
        candidate.truncate(comma);
    }
    candidate = candidate
        .split(' ')
        .map(|w| if w == "i" { "I" } else { w })
        .collect::<Vec<_>>()
        .join(" ");
    if candidate.is_empty() {
        return NEW_TITLE.into();
    }
    let mut chars = candidate.chars();
    if let Some(first) = chars.next() {
        candidate = first.to_uppercase().collect::<String>() + chars.as_str();
    }
    const LIMIT: usize = 38;
    if candidate.chars().count() <= LIMIT {
        return candidate;
    }
    let prefix: String = candidate.chars().take(LIMIT).collect();
    match prefix.rfind(char::is_whitespace) {
        Some(boundary) => format!("{}…", &prefix[..boundary]),
        None => format!("{prefix}…"),
    }
}

/// "10:42 AM" today, "Yesterday", else "Oct 8, 2026".
pub fn row_timestamp(at: DateTime<Utc>, now: DateTime<Local>) -> String {
    let local = at.with_timezone(&Local);
    let today = now.date_naive();
    if local.date_naive() == today {
        local
            .format_localized(
                lokalbot_i18n::date_pattern("%-I:%M %p"),
                lokalbot_i18n::date_locale(),
            )
            .to_string()
    } else if Some(local.date_naive()) == today.pred_opt() {
        lokalbot_i18n::tr("Yesterday").into()
    } else {
        local
            .format_localized(
                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                lokalbot_i18n::date_locale(),
            )
            .to_string()
    }
}

/// Today, Yesterday, Previous 7 Days and Earlier, filtered by `query`.
pub fn sections<'a>(
    conversations: &'a [Conversation],
    query: &str,
    now: DateTime<Local>,
) -> Vec<(&'static str, Vec<&'a Conversation>)> {
    let query = query.trim().to_lowercase();
    let today = now.date_naive();
    let yesterday = today.pred_opt();
    let week_start = today.checked_sub_days(Days::new(7)).unwrap_or(today);
    let matching = conversations.iter().filter(|c| {
        query.is_empty()
            || c.title.to_lowercase().contains(&query)
            || c.messages
                .iter()
                .any(|m| m.text.to_lowercase().contains(&query))
    });
    let mut groups: [(&'static str, Vec<&Conversation>); 4] = [
        (lokalbot_i18n::tr("Today"), Vec::new()),
        (lokalbot_i18n::tr("Yesterday"), Vec::new()),
        (lokalbot_i18n::tr("Previous 7 Days"), Vec::new()),
        (lokalbot_i18n::tr("Earlier"), Vec::new()),
    ];
    for conversation in matching {
        let day = conversation.updated_at.with_timezone(&Local).date_naive();
        let slot = if day == today {
            0
        } else if Some(day) == yesterday {
            1
        } else if day >= week_start {
            2
        } else {
            3
        };
        groups[slot].1.push(conversation);
    }
    groups
        .into_iter()
        .filter(|(_, items)| !items.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone as _;

    fn conversation(title: &str, updated: DateTime<Utc>) -> Conversation {
        Conversation {
            id: uuid::Uuid::new_v4(),
            title: title.into(),
            created_at: updated,
            updated_at: updated,
            messages: Vec::new(),
        }
    }

    #[test]
    fn titles_are_compacted_like_the_mac() {
        assert_eq!(
            compact_title("please tell me what i decided about Redis"),
            "What I decided about Redis"
        );
        assert_eq!(
            compact_title(
                "What did we decide about the caching layer and the cluster rollout plan?"
            ),
            "What did we decide about the caching…"
        );
        assert_eq!(compact_title("   "), NEW_TITLE);
    }

    #[test]
    fn groups_by_day() {
        let now = Local.with_ymd_and_hms(2026, 10, 18, 12, 0, 0).unwrap();
        let utc = |days: i64| (now - chrono::Duration::days(days)).with_timezone(&Utc);
        let list = vec![
            conversation("a", utc(0)),
            conversation("b", utc(1)),
            conversation("c", utc(3)),
            conversation("d", utc(30)),
        ];
        let groups = sections(&list, "", now);
        let titles: Vec<&str> = groups.iter().map(|(t, _)| *t).collect();
        assert_eq!(titles, ["Today", "Yesterday", "Previous 7 Days", "Earlier"]);
        assert_eq!(sections(&list, "c", now).len(), 1);
        assert_eq!(row_timestamp(utc(1), now), "Yesterday");
    }
}
