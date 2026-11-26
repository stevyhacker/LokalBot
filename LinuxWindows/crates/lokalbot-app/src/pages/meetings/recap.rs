use std::path::{Path, PathBuf};

use lokalbot_core::ActionStatus;
use serde::{Deserialize, Serialize};

use super::model::{MeetingAction, MeetingDoc, date_label, duration_label};

pub const WEBSITE_URL: &str = "https://www.lokalbot.com/";
pub const ATTRIBUTION_TOGGLE_LABEL: &str =
    "Include 'Captured locally with LokalBot (no meeting bot)'";
pub const PLAIN_ATTRIBUTION_LINE: &str =
    "Notes captured locally with LokalBot (no meeting bot) · https://www.lokalbot.com/";

const PREFS_FILE: &str = "recap-preferences.json";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecapPreferences {
    #[serde(default)]
    include_recap_attribution: bool,
}

fn prefs_path(root: &Path) -> PathBuf {
    root.join(PREFS_FILE)
}

pub fn load_include_attribution(root: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(prefs_path(root)) else {
        return false;
    };
    serde_json::from_str::<RecapPreferences>(&text)
        .map(|prefs| prefs.include_recap_attribution)
        .unwrap_or(false)
}

pub fn save_include_attribution(root: &Path, include: bool) {
    let prefs = RecapPreferences {
        include_recap_attribution: include,
    };
    let Ok(text) = serde_json::to_string(&prefs) else {
        return;
    };
    if let Err(err) = lokalbot_core::library::write_atomic(&prefs_path(root), text.as_bytes()) {
        log::warn!("could not save recap attribution preference: {err:#}");
    }
}

pub fn follow_up_copy_text(subject: &str, body: &str, include_attribution: bool) -> String {
    let base = format!("Subject: {subject}\n\n{body}");
    if include_attribution {
        format!("{base}\n\n{PLAIN_ATTRIBUTION_LINE}")
    } else {
        base
    }
}

pub fn slack_or_email_recap(doc: &MeetingDoc, include_attribution: bool) -> String {
    let decisions: Vec<String> = doc
        .shown_decisions()
        .iter()
        .map(|d| d.text.trim().to_string())
        .filter(|text| !text.is_empty())
        .collect();
    let actions: Vec<RecapAction> = doc.shown_actions().iter().map(RecapAction::from).collect();
    let questions: Vec<String> = doc
        .shown_questions()
        .iter()
        .map(|q| q.trim().to_string())
        .filter(|q| !q.is_empty())
        .collect();
    let app_name = (!doc.meeting.is_merged_meeting() && !doc.meeting.app_name.is_empty())
        .then_some(doc.meeting.app_name.as_str());
    format_slack_or_email_recap(
        &RecapInput {
            title: &doc.meeting.display_title(),
            date: &date_label(doc.meeting.started_at),
            duration: &duration_label(&doc.meeting),
            app_name,
            summary: doc.summary.as_deref(),
            decisions: &decisions,
            actions: &actions,
            open_questions: &questions,
            turns: &[],
        },
        include_attribution,
    )
}

pub fn static_html(doc: &MeetingDoc) -> String {
    let decisions: Vec<String> = doc
        .shown_decisions()
        .iter()
        .map(|d| d.text.trim().to_string())
        .filter(|text| !text.is_empty())
        .collect();
    let actions: Vec<RecapAction> = doc.shown_actions().iter().map(RecapAction::from).collect();
    let questions: Vec<String> = doc
        .shown_questions()
        .iter()
        .map(|q| q.trim().to_string())
        .filter(|q| !q.is_empty())
        .collect();
    let turns: Vec<RecapTurn> = doc
        .rows
        .iter()
        .map(|row| RecapTurn {
            stamp: lokalbot_core::time::stamp(row.start),
            speaker: row.name.to_string(),
            text: row.text.to_string(),
        })
        .collect();
    let app_name = (!doc.meeting.is_merged_meeting() && !doc.meeting.app_name.is_empty())
        .then_some(doc.meeting.app_name.as_str());
    format_static_html(&RecapInput {
        title: &doc.meeting.display_title(),
        date: &date_label(doc.meeting.started_at),
        duration: &duration_label(&doc.meeting),
        app_name,
        summary: doc.summary.as_deref(),
        decisions: &decisions,
        actions: &actions,
        open_questions: &questions,
        turns: &turns,
    })
}

struct RecapAction {
    text: String,
    owner: Option<String>,
    due: Option<String>,
    done: bool,
}

impl From<&MeetingAction> for RecapAction {
    fn from(action: &MeetingAction) -> Self {
        let owner = action
            .owner_label
            .as_deref()
            .or(action.owner.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let due = action
            .due_label
            .as_deref()
            .or(action.due.as_deref())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        Self {
            text: action.text.clone(),
            owner,
            due,
            done: action.status == ActionStatus::Done,
        }
    }
}

struct RecapTurn {
    stamp: String,
    speaker: String,
    text: String,
}

struct RecapInput<'a> {
    title: &'a str,
    date: &'a str,
    duration: &'a str,
    app_name: Option<&'a str>,
    summary: Option<&'a str>,
    decisions: &'a [String],
    actions: &'a [RecapAction],
    open_questions: &'a [String],
    turns: &'a [RecapTurn],
}

fn format_slack_or_email_recap(input: &RecapInput<'_>, include_attribution: bool) -> String {
    let mut blocks = Vec::new();
    let mut header = format!("*{}* — {} · {}", input.title, input.date, input.duration);
    if let Some(app_name) = input.app_name.filter(|name| !name.is_empty()) {
        header.push_str(&format!(" · {app_name}"));
    }
    blocks.push(header);

    if !input.decisions.is_empty() {
        let lines = input
            .decisions
            .iter()
            .map(|d| format!("• {d}"))
            .collect::<Vec<_>>()
            .join("\n");
        blocks.push(format!("*Decisions*\n{lines}"));
    }

    let open_actions: Vec<&RecapAction> = input.actions.iter().filter(|a| !a.done).collect();
    if !open_actions.is_empty() {
        let lines = open_actions
            .iter()
            .map(|action| {
                let mut line = format!("• [ ] {}", action.text);
                let mut meta = Vec::new();
                if let Some(owner) = action.owner.as_deref().filter(|s| !s.is_empty()) {
                    meta.push(owner.to_string());
                }
                if let Some(due) = action.due.as_deref().filter(|s| !s.is_empty()) {
                    meta.push(format!("due {due}"));
                }
                if !meta.is_empty() {
                    line.push_str(&format!(" ({})", meta.join(", ")));
                }
                line
            })
            .collect::<Vec<_>>()
            .join("\n");
        blocks.push(format!("*Action items*\n{lines}"));
    }

    if !input.open_questions.is_empty() {
        let lines = input
            .open_questions
            .iter()
            .map(|q| format!("• {q}"))
            .collect::<Vec<_>>()
            .join("\n");
        blocks.push(format!("*Open questions*\n{lines}"));
    }

    if let Some(summary) = input.summary.map(str::trim).filter(|s| !s.is_empty()) {
        let cleaned = clean_markdown_for_plain_recap(summary);
        if !cleaned.is_empty() {
            blocks.push(format!("*Notes*\n{cleaned}"));
        }
    }

    if include_attribution {
        blocks.push(format!("_{PLAIN_ATTRIBUTION_LINE}_"));
    }

    blocks.join("\n\n")
}

fn format_static_html(input: &RecapInput<'_>) -> String {
    let title = escape_html(input.title);
    let mut meta_parts = vec![escape_html(input.date), escape_html(input.duration)];
    if let Some(app_name) = input.app_name.filter(|name| !name.is_empty()) {
        meta_parts.push(escape_html(app_name));
    }
    let meta_line = meta_parts.join(" &middot; ");

    let mut sections = Vec::new();

    if !input.decisions.is_empty() {
        let items = input
            .decisions
            .iter()
            .map(|d| format!("<li>{}</li>", escape_html(d)))
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!(
            "<section class=\"card\">\n  <h2>Decisions</h2>\n  <ul class=\"clean-list\">\n    {items}\n  </ul>\n</section>"
        ));
    }

    if !input.actions.is_empty() {
        let items = input
            .actions
            .iter()
            .map(|action| {
                let marker = if action.done { "&#x2611;" } else { "&#x2610;" };
                let mut badges = Vec::new();
                if let Some(owner) = action.owner.as_deref().filter(|s| !s.is_empty()) {
                    badges.push(format!("<span class=\"pill\">{}</span>", escape_html(owner)));
                }
                if let Some(due) = action.due.as_deref().filter(|s| !s.is_empty()) {
                    badges.push(format!(
                        "<span class=\"pill pill-due\">{}</span>",
                        escape_html(due)
                    ));
                }
                let badge_html = if badges.is_empty() {
                    String::new()
                } else {
                    format!(" <span class=\"pills\">{}</span>", badges.join(" "))
                };
                let cls = if action.done { " class=\"done\"" } else { "" };
                format!(
                    "<li{cls}><span class=\"box\" aria-hidden=\"true\">{marker}</span><span>{}{badge_html}</span></li>",
                    escape_html(&action.text)
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!(
            "<section class=\"card\">\n  <h2>Action items</h2>\n  <ul class=\"action-list\">\n    {items}\n  </ul>\n</section>"
        ));
    }

    if let Some(summary) = input.summary.map(str::trim).filter(|s| !s.is_empty()) {
        let rendered = render_simple_markdown_html(summary);
        sections.push(format!(
            "<section class=\"card prose\">\n  <h2>Summary</h2>\n  {rendered}\n</section>"
        ));
    }

    if !input.open_questions.is_empty() {
        let items = input
            .open_questions
            .iter()
            .map(|q| format!("<li>{}</li>", escape_html(q)))
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!(
            "<section class=\"card\">\n  <h2>Open questions</h2>\n  <ul class=\"clean-list\">\n    {items}\n  </ul>\n</section>"
        ));
    }

    if !input.turns.is_empty() {
        let rows = input
            .turns
            .iter()
            .map(|turn| {
                format!(
                    "<div class=\"turn\"><span class=\"stamp\">{}</span><span class=\"speaker\">{}</span><span class=\"utterance\">{}</span></div>",
                    escape_html(&turn.stamp),
                    escape_html(&turn.speaker),
                    escape_html(&turn.text)
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!(
            "<details class=\"card transcript\">\n  <summary>Full transcript ({} segments)</summary>\n  <div class=\"turns\">\n    {rows}\n  </div>\n</details>",
            input.turns.len()
        ));
    }

    let body_content = if sections.is_empty() {
        "<section class=\"card\"><p class=\"muted\">No notes or transcript were recorded for this meeting yet.</p></section>".to_string()
    } else {
        sections.join("\n")
    };

    format!(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — Meeting Recap</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #f6f8fa;
    --surface: #ffffff;
    --border: #dfe6ec;
    --text: #111827;
    --dim: #4b5563;
    --accent: #0f9d8a;
    --pill-bg: #eef4f7;
    --due-bg: #fef3c7;
    --due-fg: #92400e;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #080d14;
      --surface: #0e1621;
      --border: #1e2c3c;
      --text: #ecf3f7;
      --dim: #9db0bf;
      --accent: #23c4ae;
      --pill-bg: #162230;
      --due-bg: #32240d;
      --due-fg: #fbbf24;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
  main {{ max-width: 780px; margin: 0 auto; padding: 36px 20px 64px; }}
  header {{ margin-bottom: 24px; }}
  h1 {{ margin: 0 0 6px; font-size: 28px; line-height: 1.2; letter-spacing: -0.02em; }}
  .meta {{ color: var(--dim); font-size: 14px; margin: 0; }}
  .card {{ background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 20px 22px; margin-bottom: 16px; }}
  .card h2 {{ margin: 0 0 12px; font-size: 14px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--accent); }}
  .clean-list, .action-list {{ margin: 0; padding-left: 20px; }}
  .action-list {{ list-style: none; padding-left: 0; }}
  .action-list li {{ display: flex; gap: 10px; align-items: baseline; margin: 8px 0; }}
  .action-list li.done {{ opacity: 0.6; text-decoration: line-through; }}
  .box {{ font-family: ui-monospace, Menlo, monospace; color: var(--accent); }}
  .pills {{ display: inline-flex; flex-wrap: wrap; gap: 6px; margin-left: 6px; }}
  .pill {{ font-size: 12px; padding: 2px 8px; border-radius: 999px; background: var(--pill-bg); color: var(--dim); }}
  .pill-due {{ background: var(--due-bg); color: var(--due-fg); }}
  .prose h3 {{ margin: 16px 0 6px; font-size: 16px; }}
  .prose p {{ margin: 0 0 10px; }}
  .prose ul {{ margin: 0 0 10px; padding-left: 20px; }}
  .transcript summary {{ cursor: pointer; font-weight: 600; color: var(--text); }}
  .turns {{ margin-top: 14px; display: grid; gap: 10px; font-size: 14px; }}
  .turn {{ display: grid; grid-template-columns: 56px 110px 1fr; gap: 10px; align-items: baseline; }}
  @media (max-width: 600px) {{ .turn {{ grid-template-columns: 1fr; gap: 2px; }} }}
  .stamp {{ font-family: ui-monospace, Menlo, monospace; font-size: 12px; color: var(--dim); }}
  .speaker {{ font-weight: 600; color: var(--accent); overflow-wrap: anywhere; }}
  .muted {{ color: var(--dim); margin: 0; }}
  footer {{ margin-top: 28px; padding-top: 16px; border-top: 1px solid var(--border); font-size: 13px; color: var(--dim); }}
  footer a {{ color: var(--accent); text-decoration: none; }}
  footer a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>
<main>
  <header>
    <h1>{title}</h1>
    <p class="meta">{meta_line}</p>
  </header>
  {body_content}
  <footer>
    Captured locally with <a href="{WEBSITE_URL}">LokalBot</a> — no meeting bot joined this call.
  </footer>
</main>
</body>
</html>"#
    )
}

pub fn escape_html(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn clean_markdown_for_plain_recap(markdown: &str) -> String {
    markdown
        .lines()
        .map(|line| {
            let trimmed = line.trim();
            if let Some(rest) = trimmed.strip_prefix("### ") {
                format!("*{rest}*")
            } else if let Some(rest) = trimmed.strip_prefix("## ") {
                format!("*{rest}*")
            } else if let Some(rest) = trimmed.strip_prefix("# ") {
                format!("*{rest}*")
            } else if let Some(rest) = trimmed.strip_prefix("- ") {
                format!("• {rest}")
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

fn render_simple_markdown_html(markdown: &str) -> String {
    let mut html = Vec::new();
    let mut in_list = false;
    for raw_line in markdown.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            if in_list {
                html.push("</ul>".to_string());
                in_list = false;
            }
            continue;
        }
        if let Some(rest) = trimmed
            .strip_prefix("- ")
            .or_else(|| trimmed.strip_prefix("* "))
        {
            if !in_list {
                html.push("<ul>".to_string());
                in_list = true;
            }
            html.push(format!("<li>{}</li>", escape_html(rest)));
        } else if trimmed.starts_with('#') {
            if in_list {
                html.push("</ul>".to_string());
                in_list = false;
            }
            let heading = trimmed.trim_start_matches('#').trim();
            if !heading.is_empty() {
                html.push(format!("<h3>{}</h3>", escape_html(heading)));
            }
        } else {
            if in_list {
                html.push("</ul>".to_string());
                in_list = false;
            }
            html.push(format!("<p>{}</p>", escape_html(trimmed)));
        }
    }
    if in_list {
        html.push("</ul>".to_string());
    }
    html.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slack_recap_omits_attribution_by_default_and_includes_it_when_opted_in() {
        let decisions = vec!["Cap retries at 3 attempts".to_string()];
        let actions = vec![
            RecapAction {
                text: "Ship v2 rate limiter".into(),
                owner: Some("Maya".into()),
                due: Some("Friday".into()),
                done: false,
            },
            RecapAction {
                text: "Already finished".into(),
                owner: None,
                due: None,
                done: true,
            },
        ];
        let questions = vec!["Should legacy webhooks warn for 30 days?".to_string()];
        let input = RecapInput {
            title: "API Launch & <Review>",
            date: "Nov 19, 2026",
            duration: "30 min",
            app_name: Some("Zoom"),
            summary: Some("## Overview\n- Agreed on rollout plan"),
            decisions: &decisions,
            actions: &actions,
            open_questions: &questions,
            turns: &[],
        };

        let plain = format_slack_or_email_recap(&input, false);
        assert!(plain.contains("*API Launch & <Review>* — Nov 19, 2026 · 30 min · Zoom"));
        assert!(plain.contains("*Decisions*\n• Cap retries at 3 attempts"));
        assert!(plain.contains("*Action items*\n• [ ] Ship v2 rate limiter (Maya, due Friday)"));
        assert!(!plain.contains("Already finished"));
        assert!(plain.contains("*Open questions*\n• Should legacy webhooks warn for 30 days?"));
        assert!(plain.contains("• Agreed on rollout plan"));
        assert!(!plain.contains("lokalbot.com"));

        let attributed = format_slack_or_email_recap(&input, true);
        assert!(attributed.contains(PLAIN_ATTRIBUTION_LINE));
        assert!(attributed.contains("lokalbot.com"));
    }

    #[test]
    fn follow_up_copy_text_respects_opt_in_attribution() {
        let plain = follow_up_copy_text("Sync notes", "Action items below.", false);
        assert_eq!(plain, "Subject: Sync notes\n\nAction items below.");
        assert!(!plain.contains("lokalbot.com"));

        let attributed = follow_up_copy_text("Sync notes", "Action items below.", true);
        assert!(attributed.contains(PLAIN_ATTRIBUTION_LINE));
    }

    #[test]
    fn static_html_is_self_contained_and_escapes_markup() {
        let decisions = vec!["Use local-only processing".to_string()];
        let actions = vec![RecapAction {
            text: "Audit <script>alert(1)</script>".into(),
            owner: Some("Sam".into()),
            due: Some("Monday".into()),
            done: false,
        }];
        let turns = vec![RecapTurn {
            stamp: "00:12".into(),
            speaker: "Maya".into(),
            text: "Let's keep it <local>.".into(),
        }];
        let html = format_static_html(&RecapInput {
            title: "API Launch & <Review>",
            date: "Nov 19, 2026",
            duration: "30 min",
            app_name: Some("Zoom"),
            summary: Some("### Summary\n- Ready to ship"),
            decisions: &decisions,
            actions: &actions,
            open_questions: &[],
            turns: &turns,
        });

        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("API Launch &amp; &lt;Review&gt;"));
        assert!(html.contains("Audit &lt;script&gt;alert(1)&lt;/script&gt;"));
        assert!(!html.contains("<script>alert(1)</script>"));
        assert!(html.contains("Full transcript (1 segments)"));
        assert!(html.contains("Let&#39;s keep it &lt;local&gt;."));
        assert!(html.contains(WEBSITE_URL));
        assert!(!html.contains("<script"));
        assert!(!html.contains("<link"));
    }

    #[test]
    fn attribution_preference_defaults_off_and_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!load_include_attribution(dir.path()));
        save_include_attribution(dir.path(), true);
        assert!(load_include_attribution(dir.path()));
        save_include_attribution(dir.path(), false);
        assert!(!load_include_attribution(dir.path()));
    }
}
