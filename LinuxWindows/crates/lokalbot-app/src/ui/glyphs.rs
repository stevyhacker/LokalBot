//! Composite symbols that Lucide lacks.

use gpui_kit::{Div, Hsla, ParentElement as _, Pixels, Styled as _, div};

use super::{Ico, icon};

/// `sparkle.magnifyingglass`: a magnifier with a sparkle in its lens.
pub fn ask_glyph(size: Pixels, color: Hsla) -> Div {
    let sparkle = size * 0.42;
    // Lucide's lens is centred at (11, 11) of a 24-unit box.
    let center = size * (11.0 / 24.0);
    div()
        .relative()
        .size(size)
        .flex_none()
        .child(icon(Ico::Search, size, color))
        .child(
            div()
                .absolute()
                .left(center - sparkle / 2.)
                .top(center - sparkle / 2.)
                .child(icon(Ico::Sparkle, sparkle, color)),
        )
}
