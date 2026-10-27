//! Button presets in LokalBot's three styles: filled teal (primary),
//! bordered (secondary actions) and quiet icon buttons for toolbars.

use gpui_kit::ElementId;
use gpui_kit::SharedString;
use gpui_kit::component::Icon;
use gpui_kit::component::button::{Button, ButtonVariants as _};

use super::Ico;

/// macOS `.bordered` button for secondary actions ("Review Actions…"): a soft
/// grey fill with accent text (colors come from the theme's secondary button).
pub fn bordered(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Button {
    Button::new(id).secondary().label(label)
}

/// Bordered button with a leading icon.
pub fn bordered_icon(
    id: impl Into<ElementId>,
    icon: Ico,
    label: impl Into<SharedString>,
) -> Button {
    Button::new(id)
        .secondary()
        .icon(Icon::new(icon))
        .label(label)
}

/// Icon-only toolbar button with a tooltip.
pub fn toolbar_icon(
    id: impl Into<ElementId>,
    icon: Ico,
    tooltip: impl Into<SharedString>,
) -> Button {
    Button::new(id)
        .ghost()
        .icon(Icon::new(icon))
        .tooltip(tooltip)
}
