//! Markdown for summaries and digests, with headings scaled to sit under
//! LokalBot's section titles instead of dwarfing them.

use gpui_kit::component::text::{TextView, TextViewStyle};
use gpui_kit::{ElementId, SharedString, px, rems};

pub fn markdown(id: impl Into<ElementId>, text: impl Into<SharedString>) -> TextView {
    let style = TextViewStyle::default()
        .paragraph_gap(rems(0.6))
        .heading_font_size(|level, _| match level {
            1 => px(18.),
            2 => px(16.),
            _ => px(14.),
        });
    TextView::markdown(id, text).style(style).selectable(true)
}
