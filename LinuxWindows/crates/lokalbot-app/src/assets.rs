//! Embedded assets: Inter, the app icon, and the Lucide icons LokalBot uses.

use std::borrow::Cow;

use gpui_kit::{App, AssetSource, Result, SharedString};

// Lucide icons beyond GPUI Kit's default component set. Add a name here before
// using `Icon::new(LbIcon::…)` with it; unknown names render as nothing.
gpui_kit::assets::icon_assets!(pub ExtraIcons, [
    Activity, AppWindow, ArrowDownLeft, ArrowRightLeft, ArrowUpDown, ArrowUpRight, AudioLines,
    BadgeCheck, Bookmark, BookmarkCheck, Brain, Briefcase, Camera, ChartGantt, Circle,
    CircleArrowDown, CircleArrowUp, CircleCheckBig, CircleDot, CircleEllipsis, CircleQuestionMark,
    CircleStop, Clock, Contrast, CornerDownLeft, CornerDownRight, Crosshair, Expand, FileSearch,
    Hourglass, ImageOff, Keyboard, Layers, LayoutGrid, Link, ListChecks, Lock, MessageSquareQuote,
    MessageSquareText, MessagesSquare, Monitor, Package, Pencil, Quote, RotateCcw, ScanText, Share,
    ShieldCheck, SlidersHorizontal, Sparkle, Sparkles, SquareArrowOutUpRight, SquarePen, Terminal,
    TextCursorInput, TextQuote, TextSearch, Trash, UserRoundCheck, Users, Video, Volume2,
    WandSparkles, X, ZoomIn, ZoomOut,
    // Agent Mode
    Archive, CirclePlus, Download, Hand, ListPlus, LockOpen,
    // Meeting import, merge and boundaries
    Group, Import,
    // Phones and tablets
    Smartphone, Tablet,
    // Selection actions
    ClipboardCheck, Languages, Lightbulb, Minimize2, Reply, TextAlignStart, TextCursor,
    // Files
    FileCode, FileHeadphone, FileImage, FileVideoCamera,
    // Sidebar: Timeline (calendar.day.timeline.left) and the privacy line (lock.shield)
    SquareChartGantt, ShieldLock,
    // Timeline panels: Work Summary (list.bullet), Decisions (flag), Screen moments (photo)
    List, Flag, Image,
]);

/// Serves LokalBot's own files first, then the extra icons, then GPUI Kit's defaults.
pub struct Assets;

const BRAND_ICON: &[u8] = include_bytes!("../assets/icons/lokalbot.svg");

impl AssetSource for Assets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if path == "brand/lokalbot.svg" {
            return Ok(Some(Cow::Borrowed(BRAND_ICON)));
        }
        if let Some(bytes) = ExtraIcons.load(path)? {
            return Ok(Some(bytes));
        }
        gpui_kit::assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut items = ExtraIcons.list(path)?;
        items.extend(gpui_kit::assets::Assets.list(path)?);
        items.sort();
        items.dedup();
        Ok(items)
    }
}

/// Registers the bundled Inter faces. The UI uses Inter on every platform so
/// layouts and screenshots look the same on Linux and Windows.
pub fn load_fonts(cx: &mut App) {
    // Geist and Geist Mono 1.900 and Inter 4.001, all SIL OFL 1.1. See `theme::FONT_FAMILY`.
    let fonts: Vec<Cow<'static, [u8]>> = vec![
        Cow::Borrowed(include_bytes!("../assets/fonts/Geist-Regular.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Geist-Medium.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Geist-SemiBold.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Geist-Bold.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/GeistMono-Regular.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/GeistMono-Medium.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/GeistMono-SemiBold.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/GeistMono-Bold.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Inter-Regular.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Inter-Medium.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Inter-SemiBold.ttf")),
        Cow::Borrowed(include_bytes!("../assets/fonts/Inter-Bold.ttf")),
    ];
    if let Err(err) = cx.text_system().add_fonts(fonts) {
        log::warn!("could not load the bundled fonts: {err:#}");
    }
}
