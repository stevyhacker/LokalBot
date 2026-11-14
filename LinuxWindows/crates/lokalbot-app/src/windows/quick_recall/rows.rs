//! One row of the Quick Recall window (`QuickRecallRowModel.swift`,
//! `QuickRecallRow.swift`): a meeting, a screen moment, a file, a saved agent
//! note or a command. Line one is the title, a grey qualifier (the app, the
//! folder, a meeting's length) and when; line two is the matching line,
//! starting with who said it for a meeting.

use chrono::{DateTime, Local, Utc};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, Div, FontWeight, HighlightStyle, Hsla, InteractiveElement as _, ParentElement as _,
    SharedString, Stateful, StatefulInteractiveElement as _, Styled as _, StyledText, div, px,
};
use lokalbot_core::files::FileHit;
use lokalbot_core::search::DocKind;
use lokalbot_core::{Meeting, ScreenMoment};
use uuid::Uuid;

use super::model::{self, Group};
use crate::i18n::h_flex;
use crate::pages::ask::search::{self, MeetingGroup, ScreenResult};
use crate::palette::PaletteCommand;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::screen_thumbnail;
use crate::ui::{self, Ico, result_row};
use crate::windows::screen_image::ScreenImage;

/// A row's leading tile (`QuickRecallLeadView.size`).
pub const LEAD_WIDTH: f32 = 44.;
pub const LEAD_HEIGHT: f32 = 30.;

/// What leads a row.
#[derive(Clone, Debug, PartialEq)]
pub enum Lead {
    /// A screen moment's thumbnail.
    Thumbnail(Box<ScreenMoment>),
    /// A tile with an icon: a meeting's waveform, a command's icon.
    Symbol(Ico),
    /// The red dot of Record now.
    Recording,
}

/// What Return or a click on a row does.
#[derive(Clone, Debug)]
pub enum Destination {
    Screen(ScreenMoment),
    /// A meeting search hit: the transcript at its moment, or the summary.
    Meeting {
        id: Uuid,
        at: Option<f64>,
    },
    /// A recent meeting, opened at its start.
    RecentMeeting(Uuid),
    File(FileHit),
    Note(lokalbot_core::agent_notes::NoteHit),
    Command(PaletteCommand),
}

#[derive(Clone, Debug)]
pub struct RowModel {
    pub id: String,
    pub lead: Lead,
    pub title: String,
    /// Grey text after the title.
    pub qualifier: Option<String>,
    /// Who said the matching line, or which part of the meeting it is from.
    pub speaker: Option<String>,
    /// The matching line, with «matched» words.
    pub snippet: Option<String>,
    pub timestamp: Option<DateTime<Utc>>,
    /// A command's keyboard shortcut, shown where a result shows when.
    pub shortcut: Option<String>,
    pub saved: bool,
    pub destination: Destination,
}

fn non_empty(text: Option<String>) -> Option<String> {
    text.filter(|text| !text.trim().is_empty())
}

impl RowModel {
    /// A command's row: its icon, title, detail ("2 open") and shortcut.
    pub fn command(command: PaletteCommand) -> Self {
        Self {
            id: format!("command.{}", command.id),
            lead: if command.id == "record" && command.icon == Ico::CircleDot {
                Lead::Recording
            } else {
                Lead::Symbol(command.icon)
            },
            title: command.title.clone(),
            qualifier: non_empty(command.detail.clone()),
            speaker: None,
            snippet: None,
            timestamp: None,
            shortcut: non_empty(command.shortcut.clone()),
            saved: false,
            destination: Destination::Command(command),
        }
    }

    /// A meeting found by its words: the best match, led by who said it.
    pub fn meeting(group: &MeetingGroup) -> Self {
        let hit = &group.hits[0];
        let title = group.meeting.display_title();
        let snippet = if hit.kind == DocKind::Title {
            result_row::without_title_echo(&hit.snippet, &title)
        } else {
            Some(hit.snippet.clone())
        };
        Self {
            id: format!(
                "meeting.{}.{:?}.{}",
                group.meeting.id,
                hit.kind,
                hit.start.unwrap_or(0.0)
            ),
            lead: Lead::Symbol(Ico::AudioLines),
            speaker: meeting_lead(hit),
            snippet: non_empty(snippet),
            timestamp: Some(group.meeting.started_at),
            title,
            qualifier: None,
            shortcut: None,
            saved: false,
            destination: Destination::Meeting {
                id: group.meeting.id,
                at: hit.moment(),
            },
        }
    }

    /// A recent meeting before anything is typed: its title, length and start.
    pub fn recent_meeting(meeting: &Meeting) -> Self {
        Self {
            id: format!("recent.meeting.{}", meeting.id),
            lead: Lead::Symbol(Ico::AudioLines),
            title: meeting.display_title(),
            // Nothing while it is still recording.
            qualifier: meeting
                .ended_at
                .is_some()
                .then(|| crate::pages::meetings::model::duration_label(meeting)),
            speaker: None,
            snippet: None,
            timestamp: Some(meeting.started_at),
            shortcut: None,
            saved: false,
            destination: Destination::RecentMeeting(meeting.id),
        }
    }

    /// A screen moment: a saved one by its note, otherwise its window. A
    /// window without a title is named by its app, which is then not said
    /// twice.
    pub fn screen(moment: &ScreenMoment, snippet: Option<&str>) -> Self {
        let window = if moment.window_title.trim().is_empty() {
            moment.app.clone()
        } else {
            moment.window_title.clone()
        };
        let title = moment
            .saved_note
            .clone()
            .filter(|note| !note.trim().is_empty())
            .unwrap_or(window);
        Self {
            id: format!("screen.{}", moment.id),
            lead: Lead::Thumbnail(Box::new(moment.clone())),
            qualifier: (title != moment.app).then(|| moment.app.clone()),
            speaker: None,
            snippet: snippet.and_then(|snippet| result_row::without_title_echo(snippet, &title)),
            timestamp: Some(moment.ts),
            shortcut: None,
            saved: moment.is_saved,
            destination: Destination::Screen(moment.clone()),
            title,
        }
    }

    pub fn screen_result(result: &ScreenResult) -> Self {
        Self::screen(&result.moment, Some(&result.snippet))
    }

    pub fn file(hit: &FileHit) -> Self {
        Self {
            id: format!("file.{}", hit.id),
            lead: Lead::Symbol(search::file_icon(hit.kind)),
            title: hit.name(),
            qualifier: non_empty(Some(hit.folder())),
            speaker: hit.excerpt.as_ref().and_then(|_| file_lead(hit)),
            snippet: non_empty(hit.excerpt.clone()),
            timestamp: Some(hit.date()),
            shortcut: None,
            saved: false,
            destination: Destination::File(hit.clone()),
        }
    }

    pub fn note(hit: &lokalbot_core::agent_notes::NoteHit) -> Self {
        Self {
            id: format!("agentNote.{}", hit.id),
            lead: Lead::Symbol(Ico::FileText),
            title: hit.title.clone(),
            qualifier: non_empty(Some(hit.source_label())),
            speaker: None,
            snippet: non_empty(Some(search::note_snippet(hit))),
            timestamp: Some(hit.modified),
            shortcut: None,
            saved: false,
            destination: Destination::Note(hit.clone()),
        }
    }

    /// A command's shortcut, or when a result happened.
    fn trailing(&self, now: DateTime<Local>) -> Option<String> {
        self.shortcut
            .clone()
            .or_else(|| self.timestamp.map(|at| model::date_label(at, now)))
    }
}

/// What starts a meeting's matching line: the speaker of a transcript line
/// when the hit names one, otherwise where the words are. A title match
/// needs neither (`QuickRecallRowModel.meetingLead`).
pub fn meeting_lead(hit: &search::Hit) -> Option<String> {
    match hit.kind {
        DocKind::Segment => hit
            .speaker
            .as_deref()
            .map(search::speaker_label)
            .filter(|speaker| !speaker.trim().is_empty()),
        DocKind::Notes => Some(lokalbot_i18n::tr("Your notes").to_string()),
        DocKind::Summary => Some(lokalbot_i18n::tr("Summary").to_string()),
        DocKind::Outcome => Some(lokalbot_i18n::tr("Outcome").to_string()),
        DocKind::Title => None,
    }
}

/// Where in the file the matching line is: a PDF's page, or the time in a
/// recording or video (`QuickRecallRowModel.fileLead`).
pub fn file_lead(hit: &FileHit) -> Option<String> {
    if let Some(page) = hit.page {
        return Some(lokalbot_i18n::fill(
            lokalbot_i18n::tr("Page %lld"),
            &[&page.to_string()],
        ));
    }
    hit.seconds.map(ui::action_row::short_stamp)
}

/// The rows of `groups` in list order, which is the keyboard's order.
pub fn flatten(groups: &[Group<RowModel>]) -> Vec<&RowModel> {
    groups.iter().flat_map(|group| group.rows.iter()).collect()
}

// ---------------------------------------------------------------- drawing

/// The colors of a row's text: white on the selected row's fill.
#[derive(Clone, Copy)]
pub struct RowColors {
    pub strong: Hsla,
    pub quiet: Hsla,
}

impl RowColors {
    pub fn new(selected: bool, cx: &App) -> Self {
        let lb = cx.lb();
        if selected {
            let white: Hsla = gpui_kit::white();
            Self {
                strong: white,
                quiet: white.opacity(0.88),
            }
        } else {
            Self {
                strong: lb.text,
                quiet: lb.text_secondary,
            }
        }
    }
}

/// The matching line's text, how long its "Speaker: " lead is, and where the
/// matched words are.
pub fn line_parts(
    speaker: Option<&str>,
    snippet: &str,
) -> (String, usize, Vec<std::ops::Range<usize>>) {
    let (text, matches) = result_row::snippet_matches(snippet);
    let lead = speaker
        .filter(|speaker| !speaker.is_empty())
        .map(|speaker| format!("{speaker}: "))
        .unwrap_or_default();
    let offset = lead.len();
    let matches = matches
        .into_iter()
        .map(|range| range.start + offset..range.end + offset)
        .collect();
    (format!("{lead}{text}"), offset, matches)
}

/// Who said it, then the line with the matched words in bold
/// (`QuickRecallRowText.matchingLine`).
pub fn matching_line(speaker: Option<&str>, snippet: &str, strong: Hsla) -> StyledText {
    let (text, lead, matches) = line_parts(speaker, snippet);
    let mut highlights = Vec::new();
    if lead > 0 {
        highlights.push((
            0..lead,
            HighlightStyle {
                color: Some(strong),
                ..Default::default()
            },
        ));
    }
    highlights.extend(matches.into_iter().map(|range| {
        (
            range,
            HighlightStyle {
                font_weight: Some(FontWeight::BOLD),
                color: Some(strong),
                ..Default::default()
            },
        )
    }));
    StyledText::new(text).with_highlights(highlights)
}

/// The two text lines of a row. An answer's sources use the same lines, with
/// a meeting's time after the title (`accessory`).
#[allow(clippy::too_many_arguments)]
pub fn row_text(
    title: &str,
    accessory: Option<Div>,
    qualifier: Option<&str>,
    trailing: Option<String>,
    speaker: Option<&str>,
    snippet: Option<&str>,
    colors: RowColors,
) -> Div {
    v_flex()
        .flex_1()
        .min_w_0()
        .gap(px(1.))
        .child(
            h_flex()
                .w_full()
                .min_w_0()
                .gap(px(7.))
                .items_center()
                .child(
                    div()
                        .min_w_0()
                        .flex_shrink(1.)
                        .truncate()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(colors.strong)
                        .child(title.to_string()),
                )
                .children(accessory)
                .when_some(qualifier, |this, qualifier| {
                    this.child(
                        div()
                            .min_w(px(24.))
                            .flex_shrink(3.)
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(colors.quiet)
                            .child(qualifier.to_string()),
                    )
                })
                .child(div().flex_1().min_w(px(10.)))
                .when_some(trailing, |this, trailing| {
                    this.child(
                        div()
                            .flex_none()
                            .whitespace_nowrap()
                            .text_size(ty::SECONDARY)
                            .text_color(colors.quiet)
                            .child(trailing),
                    )
                }),
        )
        .when_some(snippet, |this, snippet| {
            this.child(
                div()
                    .w_full()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(colors.quiet)
                    .child(matching_line(speaker, snippet, colors.strong)),
            )
        })
}

/// A tile with an icon or the record dot (`QuickRecallLeadView.tile`).
fn tile(selected: bool, cx: &App) -> Div {
    let lb = cx.lb();
    let white: Hsla = gpui_kit::white();
    div()
        .w(px(LEAD_WIDTH))
        .h(px(LEAD_HEIGHT))
        .flex_none()
        .rounded(px(6.))
        .flex()
        .items_center()
        .justify_center()
        .when(selected, |this| this.bg(white.opacity(0.2)))
        .when(!selected, |this| {
            this.bg(lb.group_fill)
                .border_1()
                .border_color(lb.group_stroke)
        })
}

/// What leads a row: a screen moment's thumbnail (with a badge when it is
/// saved) or a tile.
pub fn lead(lead: &Lead, saved: bool, selected: bool, image: Option<ScreenImage>, cx: &App) -> Div {
    let lb = cx.lb();
    let white: Hsla = gpui_kit::white();
    match lead {
        Lead::Thumbnail(moment) => div()
            .relative()
            .flex_none()
            .w(px(LEAD_WIDTH))
            .h(px(LEAD_HEIGHT))
            .child(screen_thumbnail::tile(
                image,
                moment,
                px(LEAD_WIDTH),
                px(LEAD_HEIGHT),
                cx,
            ))
            .when(saved, |this| {
                this.child(
                    div()
                        .absolute()
                        .right(px(-5.))
                        .bottom(px(-5.))
                        .size(px(15.))
                        .rounded_full()
                        .bg(lb.elevated)
                        .border_1()
                        .border_color(lb.text.opacity(0.18))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(ui::icon(Ico::Bookmark, px(8.), lb.speakers[4])),
                )
            }),
        Lead::Symbol(icon) => tile(selected, cx).child(ui::icon(
            *icon,
            px(14.),
            if selected { white } else { lb.accent_text },
        )),
        Lead::Recording => {
            tile(selected, cx).child(div().size(px(10.)).rounded_full().bg(if selected {
                white
            } else {
                lb.recording
            }))
        }
    }
}

/// The Return mark at the end of the selected row. Its slot is always
/// reserved, so selection never reflows a line.
pub fn return_hint(visible: bool) -> Div {
    div()
        .w(px(14.))
        .flex_none()
        .flex()
        .justify_end()
        .when(visible, |this| {
            this.child(ui::icon(Ico::CornerDownLeft, px(12.), gpui_kit::white()))
        })
}

/// A row's padding, and its fill when it is selected or under the pointer.
pub fn chrome(id: impl Into<gpui_kit::ElementId>, selected: bool, cx: &App) -> Stateful<Div> {
    let lb = cx.lb();
    h_flex()
        .id(id)
        .w_full()
        .min_h(px(40.))
        .gap(px(12.))
        .items_center()
        .pl(px(12.))
        .pr(px(10.))
        .py(px(5.))
        .rounded(metric::ROW_RADIUS)
        .cursor_pointer()
        .when(selected, |this| this.bg(lb.accent_fill))
        .when(!selected, |this| {
            this.hover(|s| s.bg(lb.text.opacity(0.05)))
        })
}

/// A result, a recent item or a command.
pub fn row(row: &RowModel, selected: bool, image: Option<ScreenImage>, cx: &App) -> Stateful<Div> {
    let colors = RowColors::new(selected, cx);
    chrome(
        SharedString::from(format!("quick-recall-{}", row.id)),
        selected,
        cx,
    )
    .child(lead(&row.lead, row.saved, selected, image, cx))
    .child(row_text(
        &row.title,
        None,
        row.qualifier.as_deref(),
        row.trailing(Local::now()),
        row.speaker.as_deref(),
        row.snippet.as_deref(),
        colors,
    ))
    .child(return_hint(selected))
}

/// A group's heading, with "Show all N" when more were found than are shown.
pub fn group_header(
    group: &Group<RowModel>,
    on_show_all: impl Fn(&gpui_kit::ClickEvent, &mut gpui_kit::Window, &mut App) + 'static,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    let label: SharedString =
        lokalbot_i18n::fill(lokalbot_i18n::tr("Show all %@"), &[&group.total_label()]).into();
    h_flex()
        .w_full()
        .items_center()
        .gap(px(8.))
        .pl(px(20.))
        // Ends where a row's "when" ends.
        .pr(px(44.))
        .pt(px(8.))
        .pb(px(3.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(ty::CAPTION)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(lokalbot_i18n::tr(group.kind.title_key()).to_string()),
        )
        .when(group.has_more(), |this| {
            this.child(
                div()
                    .id(SharedString::from(format!(
                        "quick-recall-show-all-{:?}",
                        group.kind
                    )))
                    .flex_none()
                    .cursor_pointer()
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(lb.accent_text)
                    .hover(|s| s.underline())
                    .child(lokalbot_i18n::directional(label.to_string()))
                    .on_click(on_show_all),
            )
        })
}

/// The quiet row pinned under the results (`QuickRecallAskRow`). Ctrl+Return
/// asks from anywhere; Return asks once the arrow keys are on this row.
pub fn ask_row(query: &str, detail: &str, selected: bool, cx: &App) -> Stateful<Div> {
    let lb = cx.lb();
    let colors = RowColors::new(selected, cx);
    let white: Hsla = gpui_kit::white();
    let title = lokalbot_i18n::fill(lokalbot_i18n::tr("Ask about “%@”"), &[query]);
    chrome("quick-recall-ask", selected, cx)
        .child(
            div()
                .w(px(LEAD_WIDTH))
                .h(px(LEAD_HEIGHT))
                .flex_none()
                .rounded(px(6.))
                .flex()
                .items_center()
                .justify_center()
                .bg(if selected {
                    white.opacity(0.2)
                } else {
                    lb.accent_fill.opacity(0.12)
                })
                .child(ui::icon(
                    Ico::Sparkle,
                    px(14.),
                    if selected { white } else { lb.accent_text },
                )),
        )
        .child(
            h_flex()
                .flex_1()
                .min_w_0()
                .gap(px(7.))
                .items_center()
                .child(
                    div()
                        .min_w_0()
                        .flex_shrink(1.)
                        .truncate()
                        .text_size(ty::BODY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(colors.strong)
                        .child(title),
                )
                .child(
                    div()
                        .min_w(px(24.))
                        .flex_shrink(3.)
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(colors.quiet)
                        .child(detail.to_string()),
                )
                .child(div().flex_1().min_w(px(10.)))
                .child(
                    div()
                        .flex_none()
                        .whitespace_nowrap()
                        .text_size(ty::SECONDARY)
                        .text_color(colors.quiet)
                        .child("Ctrl+↩"),
                ),
        )
        .child(return_hint(selected))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::palette::{CommandAction, Placement};

    fn hit(kind: DocKind, speaker: Option<&str>) -> search::Hit {
        search::Hit {
            kind,
            start: Some(12.0),
            speaker: speaker.map(str::to_string),
            snippet: "the «pilot» starts".into(),
            is_semantic: false,
        }
    }

    #[test]
    fn a_meetings_line_starts_with_who_said_it_or_where_it_is() {
        assert_eq!(
            meeting_lead(&hit(DocKind::Segment, Some("Maya Chen"))).as_deref(),
            Some("Maya Chen")
        );
        assert_eq!(meeting_lead(&hit(DocKind::Segment, Some(" "))), None);
        assert_eq!(
            meeting_lead(&hit(DocKind::Notes, None)).as_deref(),
            Some("Your notes")
        );
        assert_eq!(
            meeting_lead(&hit(DocKind::Summary, None)).as_deref(),
            Some("Summary")
        );
        assert_eq!(meeting_lead(&hit(DocKind::Title, None)), None);
    }

    #[test]
    fn the_matching_line_bolds_the_matches_after_the_speaker() {
        let (text, lead, matches) = line_parts(Some("Maya"), "ships with «captions» now");
        assert_eq!(text, "Maya: ships with captions now");
        assert_eq!(lead, "Maya: ".len());
        assert_eq!(&text[matches[0].clone()], "captions");
        let (plain, lead, matches) = line_parts(None, "«Atlas» pilot");
        assert_eq!((plain.as_str(), lead), ("Atlas pilot", 0));
        assert_eq!(&plain[matches[0].clone()], "Atlas");
    }

    fn moment(id: i64, app: &str, window_title: &str) -> ScreenMoment {
        ScreenMoment {
            id,
            ts: Utc::now(),
            app: app.into(),
            window_title: window_title.into(),
            capture_trigger: String::new(),
            path: String::new(),
            source_url: String::new(),
            document_name: String::new(),
            meeting_id: None,
            privacy_redactions: 0,
            text: None,
            saved_note: None,
            is_saved: false,
            similarity_group: 0,
        }
    }

    #[test]
    fn a_window_without_a_title_is_named_once_by_its_app() {
        let moment = moment(4, "Pages", "");
        let row = RowModel::screen(&moment, None);
        assert_eq!(row.title, "Pages");
        assert_eq!(row.qualifier, None);
        let titled = ScreenMoment {
            window_title: "Delivery checklist".into(),
            ..moment.clone()
        };
        let row = RowModel::screen(&titled, Some("«Delivery» checklist\nEvery «video»"));
        assert_eq!(row.title, "Delivery checklist");
        assert_eq!(row.qualifier.as_deref(), Some("Pages"));
        // The title is not repeated as the matching line.
        assert_eq!(row.snippet.as_deref(), Some("Every «video»"));
        // A saved moment is named by its note.
        let saved = ScreenMoment {
            saved_note: Some("Budget for laptops".into()),
            is_saved: true,
            ..titled
        };
        let row = RowModel::screen(&saved, None);
        assert_eq!(row.title, "Budget for laptops");
        assert!(row.saved);
    }

    #[test]
    fn record_now_leads_with_the_red_dot_and_shows_its_shortcut() {
        let command = PaletteCommand {
            id: "record".into(),
            icon: Ico::CircleDot,
            title: "Record now".into(),
            subtitle: "Recording".into(),
            search_aliases: String::new(),
            placement: Placement::Background,
            detail: None,
            shortcut: Some("Ctrl+Shift+R".into()),
            action: CommandAction::ToggleRecording,
        };
        let row = RowModel::command(command.clone());
        assert_eq!(row.lead, Lead::Recording);
        assert_eq!(row.trailing(Local::now()).as_deref(), Some("Ctrl+Shift+R"));
        let stop = RowModel::command(PaletteCommand {
            icon: Ico::CircleStop,
            title: "Stop recording".into(),
            ..command
        });
        assert_eq!(stop.lead, Lead::Symbol(Ico::CircleStop));
    }
}
