use gpui_kit::ElementId;
use gpui_kit::SharedString;
use gpui_kit::component::Icon;
use gpui_kit::component::button::{Button, ButtonVariants as _};

use super::Ico;

pub fn bordered(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Button {
    Button::new(id).secondary().label(label)
}

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
