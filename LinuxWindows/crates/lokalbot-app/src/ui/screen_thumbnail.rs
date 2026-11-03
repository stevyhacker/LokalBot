//! Small images of screen moments for lists (`ScreenThumbnailView`). Sealed
//! images are decrypted off the UI thread and kept in memory only: nothing is
//! written to disk, and the textures go when they fall out of the cache or the
//! list's window closes. A moment with no pixels, or one this install can't open,
//! shows a stand-in.

use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::sync::Arc;

use gpui_kit::{
    AppContext as _, Context, Div, ObjectFit, ParentElement as _, Pixels, RenderImage, Styled as _,
    StyledImage as _, Window, div, img,
};
use lokalbot_core::ScreenMoment;

use crate::state::AppData;
use crate::theme::{LbThemeExt as _, metric};
use crate::ui::{self, Ico};
use crate::windows::screen_image::{self, ScreenImage};

/// Decrypted images one surface keeps. Lists show about twenty at a time.
const MAX_THUMBNAILS: usize = 48;
const THUMBNAIL_PIXELS: u32 = 240;

#[derive(Default)]
pub struct ScreenThumbnails {
    /// `None` while loading.
    images: RefCell<HashMap<i64, Option<ScreenImage>>>,
    /// Oldest first.
    order: RefCell<VecDeque<i64>>,
    released: RefCell<Vec<Arc<RenderImage>>>,
}

impl ScreenThumbnails {
    /// A moment's image, loading it the first time it is asked for. `store` finds
    /// this cache on the view that owns it.
    pub fn image<V: 'static>(
        &self,
        moment: &ScreenMoment,
        cx: &mut Context<V>,
        store: fn(&V) -> &ScreenThumbnails,
    ) -> Option<ScreenImage> {
        if moment.path.is_empty() {
            return None;
        }
        if let Some(entry) = self.images.borrow().get(&moment.id) {
            return entry.clone();
        }
        self.track(moment.id, None);
        let library = AppData::global(cx).read(cx).library.clone();
        let loading = moment.clone();
        let id = moment.id;
        cx.spawn(async move |this, cx| {
            let image = cx
                .background_spawn(async move {
                    screen_image::load(&library, &loading, THUMBNAIL_PIXELS)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                store(this).finished(id, image);
                cx.notify();
            });
        })
        .detach();
        None
    }

    /// Stores what a load gave, unless the moment fell out while it ran.
    fn finished(&self, id: i64, image: ScreenImage) {
        if let Some(entry) = self.images.borrow_mut().get_mut(&id) {
            *entry = Some(image);
            return;
        }
        if let ScreenImage::Ready(image) = image {
            self.released.borrow_mut().push(image);
        }
    }

    fn track(&self, id: i64, entry: Option<ScreenImage>) {
        self.images.borrow_mut().insert(id, entry);
        let mut order = self.order.borrow_mut();
        order.push_back(id);
        while order.len() > MAX_THUMBNAILS {
            let Some(oldest) = order.pop_front() else {
                break;
            };
            if let Some(Some(ScreenImage::Ready(image))) = self.images.borrow_mut().remove(&oldest)
            {
                self.released.borrow_mut().push(image);
            }
        }
    }

    /// Frees the textures of images that left the cache. Call while rendering.
    pub fn drop_released(&self, window: &mut Window, cx: &mut gpui_kit::App) {
        for image in self.released.take() {
            cx.drop_image(image, Some(window));
        }
    }

    /// Forgets every image, as the window showing them closes.
    pub fn clear(&self, window: &mut Window, cx: &mut gpui_kit::App) {
        self.order.borrow_mut().clear();
        for (_, entry) in self.images.borrow_mut().drain() {
            if let Some(ScreenImage::Ready(image)) = entry {
                self.released.borrow_mut().push(image);
            }
        }
        self.drop_released(window, cx);
    }

    #[cfg(test)]
    fn held(&self) -> usize {
        self.images.borrow().len()
    }
}

/// The image filling `width`×`height`, or a stand-in in the app's color: a text
/// glyph when only text was kept, a display when the image can't be shown yet.
pub fn tile(
    image: Option<ScreenImage>,
    moment: &ScreenMoment,
    width: Pixels,
    height: Pixels,
    cx: &gpui_kit::App,
) -> Div {
    let base = div()
        .w(width)
        .h(height)
        .flex_none()
        .rounded(metric::ROW_RADIUS)
        .overflow_hidden();
    if let Some(ScreenImage::Ready(image)) = image {
        return base
            .bg(gpui_kit::black().opacity(0.82))
            .child(img(image).size_full().object_fit(ObjectFit::Cover));
    }
    let tint = cx.lb().app_color(&moment.app);
    base.bg(tint.opacity(0.16))
        .border_1()
        .border_color(tint.opacity(0.28))
        .flex()
        .items_center()
        .justify_center()
        .child(ui::icon(
            if moment.path.is_empty() {
                Ico::ScanText
            } else {
                Ico::Monitor
            },
            height * 0.4,
            tint,
        ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cache_keeps_only_the_newest_images() {
        let cache = ScreenThumbnails::default();
        for id in 0..(MAX_THUMBNAILS as i64 + 5) {
            cache.track(id, None);
        }
        assert_eq!(cache.held(), MAX_THUMBNAILS);
        assert!(!cache.images.borrow().contains_key(&0));
        assert!(cache.images.borrow().contains_key(&(MAX_THUMBNAILS as i64)));
        // A load that finishes after its moment left the cache keeps nothing.
        cache.finished(0, ScreenImage::Unavailable("gone"));
        assert!(!cache.images.borrow().contains_key(&0));
    }
}
