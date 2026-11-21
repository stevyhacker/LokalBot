use std::borrow::Cow;

use gpui_kit::{App, AssetSource, Result, SharedString};

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
    Archive, CirclePlus, Download, Hand, ListPlus, LockOpen,
    Group, Import,
    Smartphone, Tablet,
    ClipboardCheck, Languages, Lightbulb, Minimize2, Reply, TextAlignStart, TextCursor,
    FileCode, FileHeadphone, FileImage, FileVideoCamera,
    SquareChartGantt, ShieldLock,
    RotateCcwClock,
    ListFilter,
    Power,
    List, Flag, Image,
    Pin,
    Accessibility, KeyRound, ArrowDownToLine,
    CircleMinus,
]);

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

pub fn load_fonts(cx: &mut App) {
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
