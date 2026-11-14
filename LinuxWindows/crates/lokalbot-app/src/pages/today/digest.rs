//! The Day Digest and the day's activity overview on Timeline
//! (`DayDigestCard.swift`, `DayDigestView.swift`, `DayActivityOverview.swift`).
//! Today's So far today shows only the digest's highlights and when it was
//! written, with `hm` and `digest_updated_at` from here.

use chrono::{DateTime, NaiveDate, Utc};
use gpui_kit::{App, AppContext as _, Entity, Hsla};
use lokalbot_core::{DayActivity, DayDigest};

use crate::state::AppData;
use crate::theme::LbThemeExt as _;

/// `CaptureStyle.hm`: "3h 50m", "48m", "<1m" (and "0m" for nothing).
pub(crate) fn hm(seconds: f64) -> String {
    if seconds <= 0. {
        lokalbot_i18n::tr("0m").into()
    } else {
        crate::i18n::compact_duration(seconds)
    }
}

/// One proportion-bar segment: label, seconds, whether it is "Other".
pub(crate) struct AppShare {
    pub label: String,
    pub seconds: f64,
    pub is_other: bool,
}

/// Top five apps with at least a minute, then "Other" (`ProportionBarMath`).
pub(crate) fn app_shares(activity: &DayActivity) -> Vec<AppShare> {
    let mut shares = Vec::new();
    let mut other = 0.;
    for usage in activity
        .app_usage
        .iter()
        .filter(|u| !lokalbot_core::timeline::is_system_app(&u.app))
    {
        if shares.len() < 5 && usage.seconds >= 60. {
            shares.push(AppShare {
                label: usage.app.clone(),
                seconds: usage.seconds,
                is_other: false,
            });
        } else {
            other += usage.seconds;
        }
    }
    if other > 0. {
        shares.push(AppShare {
            label: lokalbot_i18n::tr("Other").into(),
            seconds: other,
            is_other: true,
        });
    }
    shares
}

pub(crate) fn share_color(share: &AppShare, cx: &App) -> Hsla {
    let lb = cx.lb();
    if share.is_other {
        lb.text_tertiary.opacity(0.8)
    } else {
        lb.app_color(&share.label)
    }
}

pub(crate) fn export_markdown(
    data: Entity<AppData>,
    day: NaiveDate,
    markdown: String,
    cx: &mut App,
) {
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let name = format!("{}.md", day.format("%Y-%m-%d"));
    let receiver = cx.prompt_for_new_path(&home, Some(&name));
    cx.spawn(async move |cx| {
        let Ok(Ok(Some(path))) = receiver.await else {
            return;
        };
        let result = cx
            .background_spawn(async move { std::fs::write(&path, markdown) })
            .await;
        data.update(cx, |data, cx| match result {
            Ok(()) => data.show_message(lokalbot_i18n::tr("Digest exported as Markdown."), cx),
            Err(err) => data.show_error(
                lokalbot_i18n::format(
                    "Digest export failed: {err}",
                    &[("err", format!("{}", err))],
                ),
                cx,
            ),
        });
    })
    .detach();
}

/// When the digest was written: its sidecar's time, else the file's.
pub(crate) fn digest_updated_at(digest: &DayDigest) -> Option<DateTime<Utc>> {
    digest
        .meta
        .as_ref()
        .map(|m| m.generated_at)
        .or(digest.modified_at)
}
