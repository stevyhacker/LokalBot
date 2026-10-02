use crate::*;
pub(crate) const BG: u32 = 0x101318;
pub(crate) const SIDEBAR: u32 = 0x0c0f13;
pub(crate) const SURFACE: u32 = 0x171b22;
pub(crate) const RAISED: u32 = 0x1d232b;
pub(crate) const BORDER: u32 = 0x29313b;
pub(crate) const TEXT: u32 = 0xe9edf2;
pub(crate) const MUTED: u32 = 0x8994a3;
pub(crate) const ACCENT: u32 = 0x73d9c4;
pub(crate) const ACCENT_BG: u32 = 0x15312d;

pub(crate) fn label(text: impl Into<SharedString>, size: f32, color: u32) -> Div {
    div()
        .min_w(px(0.))
        .whitespace_normal()
        .text_size(px(size))
        .text_color(rgb(color))
        .child(text.into())
}
pub(crate) fn heading(text: impl Into<SharedString>, size: f32) -> Div {
    label(text, size, TEXT).font_weight(FontWeight::SEMIBOLD)
}
pub(crate) fn icon(name: IconName, color: u32) -> Icon {
    Icon::new(name).w(px(17.)).h(px(17.)).text_color(rgb(color))
}
pub(crate) fn row() -> Div {
    div().flex().min_w(px(0.)).items_center().gap(px(10.))
}
pub(crate) fn column() -> Div {
    div().flex().min_w(px(0.)).flex_col()
}
pub(crate) fn panel() -> Div {
    column()
        .bg(rgb(SURFACE))
        .rounded(px(12.))
        .border_1()
        .border_color(rgb(BORDER))
}
pub(crate) fn separator() -> Div {
    div().h(px(1.)).w_full().bg(rgb(BORDER))
}
pub(crate) fn badge(text: &str, accent: bool) -> Div {
    label(text.to_owned(), 11., if accent { ACCENT } else { MUTED })
        .px(px(9.))
        .py(px(4.))
        .rounded(px(5.))
        .bg(rgb(if accent { ACCENT_BG } else { RAISED }))
}
pub(crate) fn avatar(initials: &str, tint: u32, sz: f32) -> Div {
    row()
        .justify_center()
        .w(px(sz))
        .h(px(sz))
        .flex_shrink_0()
        .rounded_full()
        .bg(rgb(tint))
        .text_color(rgb(TEXT))
        .text_size(px(sz * 0.34))
        .font_weight(FontWeight::MEDIUM)
        .child(initials.to_owned())
}
pub(crate) fn button(
    id: impl Into<ElementId>,
    text: &str,
    name: IconName,
    primary: bool,
) -> Stateful<Div> {
    row()
        .id(id)
        .gap(px(7.))
        .px(px(12.))
        .h(px(34.))
        .rounded(px(7.))
        .bg(rgb(if primary { ACCENT } else { RAISED }))
        .text_color(rgb(if primary { 0x0c2522 } else { TEXT }))
        .text_size(px(12.))
        .font_weight(FontWeight::MEDIUM)
        .cursor_pointer()
        .hover(move |s| s.bg(rgb(if primary { 0x93e6d5 } else { 0x2b343f })))
        .child(icon(name, if primary { 0x0c2522 } else { MUTED }))
        .child(text.to_owned())
}
pub(crate) fn section_header(title: &str, name: IconName, detail: &str) -> Div {
    row()
        .mb(px(14.))
        .child(icon(name, 0xb6c1ce))
        .child(heading(title.to_owned(), 14.))
        .child(div().flex_1())
        .child(label(detail.to_owned(), 11., MUTED))
}
pub(crate) fn page_header(title: &str, subtitle: &str) -> Div {
    column()
        .gap(px(6.))
        .child(heading(title.to_owned(), 27.))
        .child(label(subtitle.to_owned(), 12., MUTED))
}
