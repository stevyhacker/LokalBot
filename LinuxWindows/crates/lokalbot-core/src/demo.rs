//! A fictional demo library for screenshots, UI development and tests
//! (`Scripts/seed_demo_library.py --profile studio`, adapted to Linux and
//! Windows apps): a small video studio's meetings, actions, day memory,
//! digest, Ask conversations, people and projects, placed relative to `now`.

use std::fs;

use anyhow::{Context as _, Result, bail};
use chrono::{DateTime, Duration, Local, NaiveTime, TimeZone as _, Utc};
use uuid::Uuid;

use crate::library::{Library, write_json};
use crate::model::*;
use crate::paths::LibraryPaths;

/// Marks a directory this module created, so it may be reseeded.
pub const DEMO_MARKER: &str = ".lokalbot-demo-library";

pub const STUDIO_SHOOT: Uuid = Uuid::from_u128(0x55555555_5555_4555_8555_555555555555);
pub const STUDIO_PODCAST: Uuid = Uuid::from_u128(0x66666666_6666_4666_8666_666666666666);
const ENGINE: &str = "on-device demo";

/// `mid(n)` of the Python seeder: `{n:08}-0000-4000-8000-{n:012}`.
fn mid(n: u32) -> Uuid {
    Uuid::parse_str(&format!("{n:08}-0000-4000-8000-{n:012}")).unwrap_or_default()
}

/// When a demo meeting starts.
#[derive(Clone, Copy)]
enum When {
    /// Minutes before the anchor (today).
    Ago(i64),
    /// Local `hour:minute` on the day `days` before today.
    Day(i64, u32, u32),
}

struct Action {
    segment: usize,
    text: &'static str,
    /// `None`: the speaker of the cited segment decides (me → Me).
    owner: Option<&'static str>,
    due: Option<&'static str>,
    status: Option<ActionStatus>,
}

const fn act(segment: usize, text: &'static str, due: Option<&'static str>) -> Action {
    Action {
        segment,
        text,
        owner: None,
        due,
        status: None,
    }
}

struct Demo {
    id: Uuid,
    title: &'static str,
    app: &'static str,
    when: When,
    minutes: i64,
    system_track: bool,
    aliases: &'static [(&'static str, &'static str)],
    lines: &'static [(f64, f64, &'static str, &'static str)],
    tldr: &'static [(usize, &'static str)],
    key_points: &'static [&'static str],
    decisions: &'static [(usize, &'static str)],
    actions: Vec<Action>,
    questions: &'static [&'static str],
    notes: Option<&'static str>,
}

const MAYA: &[(&str, &str)] = &[("them", "Maya Chen")];
const JOHN: &[(&str, &str)] = &[("them", "John Park")];
const MAYA_JOHN: &[(&str, &str)] = &[("them", "Maya Chen"), ("them 2", "John Park")];

fn meetings() -> Vec<Demo> {
    vec![
        Demo {
            id: STUDIO_SHOOT,
            title: "Holiday shoot planning",
            app: "Microsoft Teams",
            when: When::Ago(60),
            minutes: 25,
            system_track: true,
            aliases: MAYA,
            lines: &[
                (
                    0.0,
                    12.0,
                    "me",
                    "Let's lock the holiday shoot. We shoot everything on phones this year.",
                ),
                (
                    12.0,
                    26.0,
                    "them",
                    "Agreed on phones for stills and video. Open question: gimbal or handheld?",
                ),
                (
                    26.0,
                    38.0,
                    "me",
                    "I'll book the photo studio for Thursday morning.",
                ),
                (
                    38.0,
                    52.0,
                    "them",
                    "I'll send the Figma shot list to the crew tonight.",
                ),
                (
                    52.0,
                    66.0,
                    "me",
                    "Fair. I'll add the props list while I'm at it.",
                ),
                (
                    66.0,
                    82.0,
                    "them",
                    "While we're here: footage handoff. Shared drive on set, or the external SSD?",
                ),
                (
                    82.0,
                    96.0,
                    "me",
                    "The shared drive for selects, the SSD for the full day.",
                ),
                (
                    96.0,
                    110.0,
                    "them",
                    "Okay. The client also wants three vertical cuts for social.",
                ),
                (
                    110.0,
                    124.0,
                    "me",
                    "Then we frame wide and crop in DaVinci Resolve. I'll note it on the call sheet.",
                ),
                (
                    124.0,
                    138.0,
                    "them",
                    "Ship it. Final walkthrough on Wednesday.",
                ),
            ],
            tldr: &[
                (
                    0,
                    "The holiday shoot is all phones this year, stills and video.",
                ),
                (2, "The photo studio is booked for Thursday morning."),
                (7, "The client wants three vertical cuts for social."),
            ],
            key_points: &[
                "Selects move over the shared drive; full shoot days go on the external SSD.",
                "Framing stays wide so the vertical cuts can be cropped in DaVinci Resolve.",
                "Final walkthrough is on Wednesday.",
            ],
            decisions: &[
                (
                    1,
                    "Shoot stills and video on phones for one consistent look.",
                ),
                (
                    6,
                    "The shared drive for selects, the external SSD for full shoot days.",
                ),
            ],
            actions: vec![
                act(
                    2,
                    "Book the photo studio for Thursday morning",
                    Some("by Thursday"),
                ),
                act(3, "Send the Figma shot list to the crew", Some("tonight")),
                act(4, "Add the props list to the call sheet", None),
            ],
            questions: &["Gimbal or handheld for the walk-and-talk shots?"],
            notes: Some(
                "- Ask the photo studio about the big softbox\n- Maya directs the B-roll\n",
            ),
        },
        Demo {
            id: mid(21),
            title: "Laptop refresh planning",
            app: "Zoom",
            when: When::Ago(102),
            minutes: 25,
            system_track: true,
            aliases: JOHN,
            lines: &[
                (
                    0.0,
                    12.0,
                    "me",
                    "Let's settle the laptop refresh. Exports take forty minutes on the old laptops.",
                ),
                (
                    12.0,
                    26.0,
                    "them",
                    "Agreed on workstation laptops for the editors. Open question: what does sales need?",
                ),
                (
                    26.0,
                    38.0,
                    "me",
                    "I'll request a business quote from the vendor by Thursday.",
                ),
                (
                    38.0,
                    52.0,
                    "them",
                    "I'll check trade-in values for the old machines before we order.",
                ),
                (
                    52.0,
                    66.0,
                    "me",
                    "Fair. Trade-ins should cover most of the extended warranty.",
                ),
                (
                    66.0,
                    82.0,
                    "them",
                    "While we're here: the edit suite. Do we add 4K monitors now or next quarter?",
                ),
                (82.0, 96.0, "me", "Next quarter. One purchase at a time."),
                (
                    96.0,
                    110.0,
                    "them",
                    "Okay. Sales mostly lives in slides and email, so a light laptop is plenty for them.",
                ),
                (
                    110.0,
                    124.0,
                    "me",
                    "Then sales gets the light model. I'll put the final list in the budget sheet.",
                ),
                (
                    124.0,
                    138.0,
                    "them",
                    "Ship it. Let's place the order once the quote is in.",
                ),
            ],
            tldr: &[
                (
                    0,
                    "Exports take forty minutes on the old laptops, so the editors move to workstation laptops.",
                ),
                (
                    2,
                    "A business quote is due by Thursday; the order waits for it.",
                ),
            ],
            key_points: &[
                "Sales mostly works in slides and email, so a light laptop is enough.",
                "Trade-ins should cover most of the extended warranty.",
            ],
            decisions: &[
                (1, "Workstation laptops for both video editors."),
                (
                    6,
                    "The 4K monitors wait until next quarter; one purchase at a time.",
                ),
            ],
            actions: vec![
                act(
                    2,
                    "Request a business quote from the vendor",
                    Some("by Thursday"),
                ),
                act(3, "Check trade-in values for the old machines", None),
                act(8, "Put the final laptop list in the budget sheet", None),
            ],
            questions: &["Does sales need anything more than a light laptop?"],
            notes: None,
        },
        Demo {
            id: mid(22),
            title: "Studio check-in",
            app: "Slack huddle",
            when: When::Ago(182),
            minutes: 15,
            system_track: false,
            aliases: &[],
            lines: &[
                (
                    0.0,
                    9.0,
                    "me",
                    "Quick check-in. I'm finishing the Northwind holiday cut today.",
                ),
                (
                    9.0,
                    20.0,
                    "me",
                    "Blocker: 4K exports still crawl on the old laptops.",
                ),
                (
                    20.0,
                    32.0,
                    "me",
                    "Also pricing two laptop configs for the edit suite before the call.",
                ),
                (
                    32.0,
                    44.0,
                    "me",
                    "And I'm sending Globex the demo presentation slides this morning.",
                ),
            ],
            tldr: &[
                (0, "The Northwind holiday cut wraps today."),
                (1, "4K exports on the old laptops are the blocker."),
            ],
            key_points: &["Two laptop configs get priced before the refresh call."],
            decisions: &[],
            actions: vec![
                act(0, "Finish the Northwind holiday cut", Some("today")),
                act(2, "Price two laptop configs for the edit suite", None),
                Action {
                    status: Some(ActionStatus::Done),
                    ..act(
                        3,
                        "Send Globex the demo presentation slides",
                        Some("this morning"),
                    )
                },
            ],
            questions: &[],
            notes: None,
        },
        Demo {
            id: STUDIO_PODCAST,
            title: "Podcast trailer review",
            app: "Google Meet",
            when: When::Day(1, 9, 57),
            minutes: 30,
            system_track: true,
            aliases: JOHN,
            lines: &[
                (
                    0.0,
                    12.0,
                    "me",
                    "The podcast trailer is two weeks late. Let's fix the cut today.",
                ),
                (
                    12.0,
                    26.0,
                    "them",
                    "Agreed on a sixty-second cut. Open question: lead with the guest or the host?",
                ),
                (
                    26.0,
                    38.0,
                    "me",
                    "I'll re-cut the intro in Reaper by Friday.",
                ),
                (
                    38.0,
                    52.0,
                    "them",
                    "Please duck the music under the voiceover; it fights the first line.",
                ),
                (
                    52.0,
                    66.0,
                    "me",
                    "Fair. I'll check the mix on earbuds and on the studio monitors.",
                ),
                (
                    66.0,
                    82.0,
                    "them",
                    "While we're here: artwork. Does the square cover work as the trailer art?",
                ),
                (
                    82.0,
                    96.0,
                    "me",
                    "It works. We reuse the episode art instead of designing a new one.",
                ),
                (
                    96.0,
                    110.0,
                    "them",
                    "Okay. Subtitles too? Half of the clips get watched on mute.",
                ),
                (
                    110.0,
                    124.0,
                    "me",
                    "Then we burn subtitles into the social clips and ship the trailer Friday.",
                ),
                (
                    124.0,
                    138.0,
                    "them",
                    "Ship it. I'll publish the trailer with Monday's episode.",
                ),
            ],
            tldr: &[
                (1, "The trailer becomes a sixty-second cut."),
                (
                    8,
                    "Subtitles go into the social clips and the trailer ships Friday.",
                ),
            ],
            key_points: &[
                "The music ducks under the voiceover; the mix is checked on earbuds and studio monitors.",
                "The trailer reuses the episode artwork.",
            ],
            decisions: &[
                (
                    6,
                    "A sixty-second trailer cut that reuses the episode artwork.",
                ),
                (3, "Duck the music under the voiceover."),
            ],
            actions: vec![
                act(2, "Re-cut the trailer intro in Reaper", Some("by Friday")),
                act(4, "Check the mix on earbuds and studio monitors", None),
                act(
                    9,
                    "Publish the trailer with Monday's episode",
                    Some("Monday"),
                ),
            ],
            questions: &["Lead with the guest or the host?"],
            notes: Some("Trailer length target: 0:58–1:02.\n"),
        },
        Demo {
            id: mid(24),
            title: "Client call – Northwind",
            app: "Microsoft Teams",
            when: When::Day(2, 9, 47),
            minutes: 40,
            system_track: true,
            aliases: &[("them", "Priya Nair")],
            lines: &[
                (
                    0.0,
                    15.0,
                    "them",
                    "We love the first cut, but legal needs captions before it goes on our site.",
                ),
                (
                    15.0,
                    30.0,
                    "me",
                    "Captions are easy. I'll deliver the captioned Northwind cut this week.",
                ),
                (
                    30.0,
                    45.0,
                    "them",
                    "Great. A quote for three social cut-downs would help us get budget approved.",
                ),
                (
                    45.0,
                    60.0,
                    "me",
                    "I'll quote three social cut-downs by tomorrow.",
                ),
            ],
            tldr: &[(
                0,
                "Northwind likes the first cut; captions are required before it goes live.",
            )],
            key_points: &["Legal blocks publishing until captions are in."],
            decisions: &[(
                1,
                "Send a captioned version and a quote for three cut-downs this week.",
            )],
            actions: vec![
                act(1, "Deliver the captioned Northwind cut", Some("this week")),
                Action {
                    status: Some(ActionStatus::Done),
                    ..act(3, "Quote three social cut-downs", Some("tomorrow"))
                },
            ],
            questions: &["Which platforms get the vertical cut-downs?"],
            notes: None,
        },
        Demo {
            id: mid(25),
            title: "Brand refresh sync",
            app: "Zoom",
            when: When::Day(2, 14, 0),
            minutes: 30,
            system_track: true,
            aliases: MAYA,
            lines: &[
                (
                    0.0,
                    16.0,
                    "me",
                    "The new logo lockups shipped. The remaining gap is the motion version.",
                ),
                (
                    16.0,
                    34.0,
                    "them",
                    "I'll deliver the animated logo as a slide asset and a high-quality video by Friday.",
                ),
                (
                    34.0,
                    50.0,
                    "me",
                    "Then we can close the brand refresh next week.",
                ),
                (
                    50.0,
                    64.0,
                    "them",
                    "Put the animated logo on the first slide of the Globex demo presentation.",
                ),
            ],
            tldr: &[(
                0,
                "The brand refresh is nearly done; the animated logo lands Friday.",
            )],
            key_points: &["The animated logo opens the Globex demo presentation."],
            decisions: &[(2, "Close the brand refresh next week.")],
            actions: vec![Action {
                owner: Some("Maya Chen"),
                ..act(
                    1,
                    "Deliver the animated logo as a slide asset and video",
                    Some("by Friday"),
                )
            }],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(26),
            title: "Weekly production sync",
            app: "Google Meet",
            when: When::Day(3, 10, 0),
            minutes: 45,
            system_track: true,
            aliases: MAYA_JOHN,
            lines: &[
                (
                    0.0,
                    18.0,
                    "me",
                    "Three things this week: Northwind captions, the trade-in list, and the shoot schedule.",
                ),
                (
                    18.0,
                    40.0,
                    "them",
                    "The phone shoot needs the big softbox. The photo studio said Thursday works.",
                ),
                (
                    40.0,
                    52.0,
                    "them 2",
                    "I can pull the trade-in list together by Friday.",
                ),
                (
                    52.0,
                    66.0,
                    "me",
                    "Booked. I'll deliver the captioned Northwind cut first. Stretch goal is cleaning up the shared photo library.",
                ),
            ],
            tldr: &[(
                0,
                "This week: Northwind captions, the trade-in list, and Thursday's shoot with a borrowed softbox.",
            )],
            key_points: &["The photo studio lends the big softbox for Thursday."],
            decisions: &[],
            actions: vec![
                act(3, "Deliver the captioned Northwind cut", None),
                Action {
                    owner: Some("John Park"),
                    ..act(2, "Pull the trade-in list together", Some("by Friday"))
                },
                Action {
                    status: Some(ActionStatus::Deferred),
                    ..act(3, "Clean up the shared photo library", None)
                },
            ],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(27),
            title: "1:1 with Maya",
            app: "Microsoft Teams",
            when: When::Day(3, 16, 0),
            minutes: 30,
            system_track: true,
            aliases: MAYA,
            lines: &[
                (
                    0.0,
                    20.0,
                    "them",
                    "The editing is going well, but I'd like to direct a shoot myself.",
                ),
                (
                    20.0,
                    38.0,
                    "me",
                    "Let's have you lead the phone shoot on Thursday. I'll add you to the call sheet.",
                ),
            ],
            tldr: &[(1, "Maya leads Thursday's phone shoot.")],
            key_points: &["Maya wants more directing experience."],
            decisions: &[(1, "Maya leads Thursday's phone shoot.")],
            actions: vec![Action {
                status: Some(ActionStatus::Done),
                ..act(1, "Add Maya to the call sheet", None)
            }],
            questions: &[],
            notes: Some("Maya: wants to direct. Follow up after the shoot on how it went.\n"),
        },
        Demo {
            id: mid(28),
            title: "Export failure review",
            app: "Zoom",
            when: When::Day(4, 11, 30),
            minutes: 35,
            system_track: true,
            aliases: JOHN,
            lines: &[
                (
                    0.0,
                    18.0,
                    "me",
                    "Timeline: the client export started at 9:12 and the laptop ran out of disk at 9:41.",
                ),
                (
                    18.0,
                    36.0,
                    "them",
                    "Root cause: the render cache sits on the internal drive, and it's nearly full.",
                ),
                (
                    36.0,
                    54.0,
                    "me",
                    "Fix is moving render caches to the external SSD. I'll do it tomorrow. One more reason for the laptop refresh.",
                ),
            ],
            tldr: &[
                (
                    0,
                    "A client export failed when an old laptop ran out of disk.",
                ),
                (2, "Render caches move to the external SSD."),
            ],
            key_points: &["The internal drives are nearly full on every old laptop."],
            decisions: &[(2, "Render caches live on the external SSD from now on.")],
            actions: vec![act(
                2,
                "Move render caches to the external SSD",
                Some("tomorrow"),
            )],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(29),
            title: "Editor hiring debrief",
            app: "Google Meet",
            when: When::Day(5, 15, 0),
            minutes: 25,
            system_track: false,
            aliases: MAYA,
            lines: &[
                (
                    0.0,
                    16.0,
                    "me",
                    "Great storytelling, a little slow in DaVinci Resolve. I'm a hire.",
                ),
                (
                    16.0,
                    32.0,
                    "them",
                    "Same read. I'll check references this week.",
                ),
            ],
            tldr: &[(0, "Both interviewers are a hire on the editor candidate.")],
            key_points: &["References are the last step."],
            decisions: &[(1, "Move the editor candidate to references.")],
            actions: vec![act(
                1,
                "Check the editor candidate's references",
                Some("this week"),
            )],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(30),
            title: "Acme podcast kickoff",
            app: "Microsoft Teams",
            when: When::Day(7, 10, 0),
            minutes: 45,
            system_track: true,
            aliases: &[("them", "Lena Fischer")],
            lines: &[
                (
                    0.0,
                    20.0,
                    "them",
                    "We want episode clips on podcast apps and YouTube every week.",
                ),
                (
                    20.0,
                    40.0,
                    "me",
                    "We record in Reaper, cut in DaVinci Resolve, and deliver both formats. I'll send the episode template.",
                ),
            ],
            tldr: &[(0, "Acme wants weekly episodes on podcast apps and YouTube.")],
            key_points: &["Recording happens in Reaper and editing in DaVinci Resolve."],
            decisions: &[],
            actions: vec![act(1, "Send Acme the episode template", None)],
            questions: &["Who on Acme's side approves each episode?"],
            notes: None,
        },
        Demo {
            id: mid(31),
            title: "Equipment budget review",
            app: "Zoom",
            when: When::Day(8, 13, 30),
            minutes: 30,
            system_track: false,
            aliases: JOHN,
            lines: &[
                (
                    0.0,
                    18.0,
                    "me",
                    "The old laptops turn five this year, and the warranty ran out on three of them.",
                ),
                (
                    18.0,
                    36.0,
                    "them",
                    "Then I'll price a laptop refresh before the end of the quarter.",
                ),
            ],
            tldr: &[(
                0,
                "Three laptops are out of warranty; a refresh gets priced before quarter end.",
            )],
            key_points: &[],
            decisions: &[],
            actions: vec![act(
                1,
                "Price a laptop refresh",
                Some("before the end of the quarter"),
            )],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(32),
            title: "Weekly all-hands",
            app: "Zoom",
            when: When::Day(9, 9, 0),
            minutes: 30,
            system_track: false,
            aliases: &[],
            lines: &[
                (
                    0.0,
                    20.0,
                    "me",
                    "Headline: the Northwind teaser passed a million views in a week.",
                ),
                (
                    20.0,
                    40.0,
                    "them",
                    "Reminder that holiday campaign plans are due Friday.",
                ),
            ],
            tldr: &[
                (0, "The Northwind teaser passed a million views."),
                (1, "Holiday campaign plans are due Friday."),
            ],
            key_points: &[],
            decisions: &[],
            actions: vec![],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(33),
            title: "Footage workflow workshop",
            app: "Google Meet",
            when: When::Day(10, 14, 0),
            minutes: 60,
            system_track: true,
            aliases: MAYA_JOHN,
            lines: &[
                (
                    0.0,
                    22.0,
                    "me",
                    "Goal: phone footage on the edit timeline within ten minutes of the last take.",
                ),
                (
                    22.0,
                    44.0,
                    "them",
                    "The shared drive works for a few clips; full shoot days need an external SSD.",
                ),
                (
                    44.0,
                    52.0,
                    "them 2",
                    "I'll order two more SSDs for the kit.",
                ),
                (
                    52.0,
                    62.0,
                    "me",
                    "Agreed. The shared drive for selects, the SSD for full days.",
                ),
            ],
            tldr: &[(
                0,
                "Target: phone footage on the timeline within ten minutes of the last take.",
            )],
            key_points: &["Two more SSDs go into the shoot kit."],
            decisions: &[(
                3,
                "The shared drive for selects, an external SSD for full shoot days.",
            )],
            actions: vec![Action {
                status: Some(ActionStatus::Done),
                ..act(2, "Order two more SSDs for the kit", None)
            }],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(34),
            title: "1:1 with Maya",
            app: "Microsoft Teams",
            when: When::Day(11, 16, 0),
            minutes: 30,
            system_track: true,
            aliases: MAYA,
            lines: &[
                (
                    0.0,
                    18.0,
                    "them",
                    "The holiday shot list is ready in Figma.",
                ),
                (
                    18.0,
                    34.0,
                    "me",
                    "Great. I'll review the shot list before Monday's planning call.",
                ),
            ],
            tldr: &[(0, "The holiday shot list is ready in Figma.")],
            key_points: &[],
            decisions: &[],
            actions: vec![Action {
                status: Some(ActionStatus::Done),
                ..act(1, "Review the holiday shot list", Some("Monday"))
            }],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(35),
            title: "Accessibility review",
            app: "Microsoft Teams",
            when: When::Day(13, 11, 0),
            minutes: 40,
            system_track: true,
            aliases: &[("them", "Priya Nair")],
            lines: &[
                (
                    0.0,
                    20.0,
                    "me",
                    "Every client video ships with captions and audio descriptions from now on.",
                ),
                (
                    20.0,
                    40.0,
                    "them",
                    "Then the delivery checklist needs an accessibility section.",
                ),
                (
                    40.0,
                    52.0,
                    "me",
                    "I'll add the accessibility section to the delivery checklist.",
                ),
            ],
            tldr: &[(
                0,
                "Captions and audio descriptions ship with every client video.",
            )],
            key_points: &["The delivery checklist gains an accessibility section."],
            decisions: &[(
                0,
                "Captions and audio descriptions ship with every client video.",
            )],
            actions: vec![act(
                2,
                "Add an accessibility section to the delivery checklist",
                None,
            )],
            questions: &[],
            notes: None,
        },
        Demo {
            id: mid(36),
            title: "Budget review Q4",
            app: "Google Meet",
            when: When::Day(14, 10, 30),
            minutes: 30,
            system_track: false,
            aliases: JOHN,
            lines: &[
                (
                    0.0,
                    18.0,
                    "them",
                    "Spend is flat. The only new line is the laptop refresh.",
                ),
                (
                    18.0,
                    34.0,
                    "me",
                    "Approved in principle. We'll size it after the trade-in quote.",
                ),
            ],
            tldr: &[(
                0,
                "The Q4 budget is approved; the laptop refresh is sized after the trade-in quote.",
            )],
            key_points: &[],
            decisions: &[(1, "Size the laptop refresh after the trade-in quote.")],
            actions: vec![],
            questions: &[],
            notes: None,
        },
    ]
}

/// Today's activity, in minutes before the anchor: (app, window title, from, to).
const TODAY_BLOCKS: &[(&str, &str, i64, i64)] = &[
    (
        "LibreOffice Impress",
        "Northwind pitch deck.odp - LibreOffice Impress",
        250,
        190,
    ),
    ("Slack", "Studio check-in - Huddle - Slack", 182, 167),
    (
        "Firefox",
        "Compare business laptops — Mozilla Firefox",
        167,
        128,
    ),
    (
        "LibreOffice Calc",
        "Laptop refresh budget.ods - LibreOffice Calc",
        128,
        102,
    ),
    ("Zoom", "Zoom Meeting", 102, 77),
    (
        "LibreOffice Writer",
        "Delivery checklist.odt - LibreOffice Writer",
        77,
        68,
    ),
    (
        "Microsoft Edge",
        "Trade-in estimate - Outlook - Microsoft\u{200b} Edge",
        68,
        60,
    ),
    (
        "Microsoft Teams",
        "Holiday shoot planning | Microsoft Teams",
        60,
        35,
    ),
    ("Figma", "Holiday shot list – Figma", 35, 28),
    ("DaVinci Resolve", "Northwind holiday cut", 27, 4),
];

/// Earlier days: (days ago, app, title, from "HH:MM", to "HH:MM") in local time.
const EARLIER_BLOCKS: &[(i64, &str, &str, &str, &str)] = &[
    (1, "Figma", "Holiday shot list – Figma", "09:00", "09:55"),
    (
        1,
        "Google Chrome",
        "Meet – Podcast trailer review - Google Chrome",
        "09:57",
        "10:27",
    ),
    (
        1,
        "LibreOffice Impress",
        "Holiday campaign deck.odp - LibreOffice Impress",
        "11:00",
        "12:30",
    ),
    (
        1,
        "Firefox",
        "Extended warranty for business — Mozilla Firefox",
        "13:30",
        "14:45",
    ),
    (1, "Slack", "#studio - Slack", "14:45", "15:10"),
    (
        1,
        "LibreOffice Impress",
        "Globex demo presentation.odp - LibreOffice Impress",
        "15:15",
        "15:35",
    ),
    (
        1,
        "Thunderbird",
        "Re: Globex demo presentation - Mozilla Thunderbird",
        "16:00",
        "16:15",
    ),
    (
        2,
        "Microsoft Teams",
        "Client call – Northwind | Microsoft Teams",
        "09:47",
        "10:27",
    ),
    (
        2,
        "LibreOffice Writer",
        "Delivery checklist.odt - LibreOffice Writer",
        "10:30",
        "12:00",
    ),
    (2, "Zoom", "Zoom Meeting", "14:00", "14:30"),
    (2, "Figma", "Logo animation – Figma", "14:30", "16:00"),
    (
        3,
        "Google Chrome",
        "Meet – Weekly production sync - Google Chrome",
        "10:00",
        "10:45",
    ),
    (3, "DaVinci Resolve", "Holiday selects", "11:00", "13:00"),
    (
        3,
        "Microsoft Teams",
        "1:1 with Maya | Microsoft Teams",
        "16:00",
        "16:30",
    ),
    (4, "Zoom", "Zoom Meeting", "11:30", "12:05"),
    (4, "Files", "Render cache", "13:00", "14:30"),
    (
        4,
        "Firefox",
        "External SSD reviews — Mozilla Firefox",
        "14:30",
        "15:00",
    ),
    (
        5,
        "Visual Studio Code",
        "export-presets.json - studio-tools - Visual Studio Code",
        "09:30",
        "11:00",
    ),
    (5, "Terminal", "ffmpeg batch export", "11:00", "11:40"),
    (
        5,
        "Google Chrome",
        "Meet – Editor hiring debrief - Google Chrome",
        "15:00",
        "15:25",
    ),
];

struct Shot {
    app: &'static str,
    title: &'static str,
    when: When,
    text: &'static str,
    note: Option<&'static str>,
    meeting: Option<Uuid>,
}

fn shots() -> Vec<Shot> {
    vec![
        Shot {
            app: "LibreOffice Impress",
            title: "Northwind pitch deck.odp - LibreOffice Impress",
            when: When::Ago(236),
            text: "Northwind holiday campaign: three hero shots, one story, all shot on phones.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "Firefox",
            title: "Compare business laptops — Mozilla Firefox",
            when: When::Ago(147),
            text: "Workstation laptop vs light laptop: displays, battery life, ports and price, side by side.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "LibreOffice Calc",
            title: "Laptop refresh budget.ods - LibreOffice Calc",
            when: When::Ago(118),
            text: "Two workstation laptops for editors, three light laptops for sales, extended warranty on all.",
            note: Some("Laptop refresh budget"),
            meeting: None,
        },
        Shot {
            app: "LibreOffice Writer",
            title: "Delivery checklist.odt - LibreOffice Writer",
            when: When::Ago(74),
            text: "Every client video ships with captions, an audio description track, and a vertical cut.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "Microsoft Edge",
            title: "Trade-in estimate - Outlook - Microsoft\u{200b} Edge",
            when: When::Ago(64),
            text: "Your trade-in estimate for five laptops is ready and valid for 14 days.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "DaVinci Resolve",
            title: "Northwind holiday cut",
            when: When::Ago(20),
            text: "Northwind holiday cut: 42 clips, 6 favorites, captions track enabled.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "LibreOffice Impress",
            title: "Globex demo presentation.odp - LibreOffice Impress",
            when: When::Day(1, 15, 24),
            text: "Globex demo presentation: case studies and the launch timeline.",
            note: None,
            meeting: None,
        },
        Shot {
            app: "Thunderbird",
            title: "Re: Globex demo presentation - Mozilla Thunderbird",
            when: When::Day(1, 16, 5),
            text: "Great demo presentation. Could you share the slides with our team?",
            note: None,
            meeting: None,
        },
    ]
}

struct Clock {
    anchor: DateTime<Utc>,
}

impl Clock {
    /// Today's items sit just before `now`; very early in the morning they
    /// move to 04:30 so Today is still populated.
    fn new(now: DateTime<Utc>) -> Self {
        let local = now.with_timezone(&Local);
        let earliest = local_time(local.date_naive(), 4, 30);
        Self {
            anchor: now.max(earliest),
        }
    }

    fn at(&self, when: When) -> DateTime<Utc> {
        match when {
            When::Ago(minutes) => self.anchor - Duration::minutes(minutes),
            When::Day(days, hour, minute) => {
                let day = self.anchor.with_timezone(&Local).date_naive() - Duration::days(days);
                local_time(day, hour, minute)
            }
        }
    }

    fn today(&self) -> chrono::NaiveDate {
        self.anchor.with_timezone(&Local).date_naive()
    }
}

fn local_time(day: chrono::NaiveDate, hour: u32, minute: u32) -> DateTime<Utc> {
    let naive = day.and_time(NaiveTime::from_hms_opt(hour, minute, 0).unwrap_or_default());
    Local
        .from_local_datetime(&naive)
        .earliest()
        .unwrap_or_else(|| Local.from_utc_datetime(&naive))
        .with_timezone(&Utc)
}

fn whole_seconds(value: DateTime<Utc>) -> DateTime<Utc> {
    DateTime::from_timestamp(value.timestamp(), 0).unwrap_or(value)
}

/// Seeds the demo library at `paths`, relative to `now`.
///
/// Refuses a non-empty directory unless an earlier seed created it (marked
/// with [`DEMO_MARKER`]); such a library is replaced.
pub fn seed(paths: &LibraryPaths, now: DateTime<Utc>) -> Result<()> {
    let root = paths.root();
    if root.exists() {
        let populated = fs::read_dir(root)
            .with_context(|| format!("reading {}", root.display()))?
            .next()
            .is_some();
        if populated {
            if !root.join(DEMO_MARKER).is_file() {
                bail!(
                    "Refusing to overwrite {}: it is not an earlier LokalBot demo library.",
                    root.display()
                );
            }
            for entry in fs::read_dir(root)? {
                let path = entry?.path();
                if path.is_dir() {
                    fs::remove_dir_all(&path)?;
                } else {
                    fs::remove_file(&path)?;
                }
            }
        }
    }
    fs::create_dir_all(root)?;
    fs::write(root.join(DEMO_MARKER), "LokalBot synthetic demo library\n")?;

    let library = Library::open(paths.clone())?;
    let clock = Clock::new(now);
    let demos = meetings();
    let mut seeded: Vec<Meeting> = Vec::new();
    for demo in &demos {
        seeded.push(write_meeting(&library, &clock, demo)?);
    }
    let shot_ids = seed_activity(&library, &clock)?;
    seed_chats(&library, &clock, &shot_ids)?;
    seed_people_and_projects(paths, &clock)?;
    seed_journals(&library, &clock, &seeded, &shot_ids)?;
    Ok(())
}

fn write_meeting(library: &Library, clock: &Clock, demo: &Demo) -> Result<Meeting> {
    let started = whole_seconds(clock.at(demo.when));
    let ended = started + Duration::minutes(demo.minutes);
    let local = started.with_timezone(&Local);
    let relative_path = format!(
        "meetings/{}/{:02}-{}",
        local.format("%Y/%m"),
        local.format("%d"),
        crate::ids::slugify(demo.title)
    );
    let meeting: Meeting = serde_json::from_value(serde_json::json!({
        "id": crate::ids::uuid_upper(&demo.id),
        "title": demo.title,
        "appName": demo.app,
        "startedAt": started.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "endedAt": ended.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "relativePath": relative_path,
        "hasSystemTrack": demo.system_track,
        "recordedDuration": (demo.minutes * 60) as f64,
    }))?;
    fs::create_dir_all(library.meeting_dir(&meeting))?;
    library.save_meeting(&meeting)?;

    let transcript = Transcript {
        segments: demo
            .lines
            .iter()
            .map(|(start, end, speaker, text)| Segment {
                start: *start,
                end: *end,
                speaker: speaker.to_string(),
                text: text.to_string(),
                confidence: None,
                timing_precision: None,
                attribution: Some(if *speaker == "me" {
                    SpeakerAttribution::microphone_user()
                } else {
                    SpeakerAttribution::system_other()
                }),
            })
            .collect(),
        engine: ENGINE.into(),
        speaker_aliases: demo
            .aliases
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        ..Default::default()
    };
    library.save_transcript(&meeting, &transcript)?;

    let citation = |index: usize| {
        let index = index.min(transcript.segments.len() - 1);
        let segment = &transcript.segments[index];
        OutcomeSourceCitation {
            meeting_id: Some(meeting.id),
            segment_id: Transcript::segment_id(index, segment),
            start: segment.start,
            end: segment.end,
            speaker: segment.speaker.clone(),
            excerpt: segment.text.chars().take(220).collect(),
        }
    };
    let mut state = OutcomeState::default();
    let actions: Vec<ActionItem> = demo
        .actions
        .iter()
        .map(|action| {
            let cited = citation(action.segment);
            let owner = action.owner.map(str::to_string).unwrap_or_else(|| {
                if cited.speaker == "me" {
                    "Me".into()
                } else {
                    transcript.speaker_name(&cited.speaker)
                }
            });
            let is_user = owner == "Me";
            let attribution = ActionAttribution {
                resolution: if is_user {
                    OwnerResolution::User
                } else {
                    OwnerResolution::Other
                },
                speaker_id: Some(cited.speaker.clone()),
                basis: if action.owner.is_some() {
                    AttributionBasis::Assignment
                } else {
                    AttributionBasis::Commitment
                },
                quote: Some(cited.excerpt.clone()),
                rejection_reason: None,
            };
            let item = ActionItem::new(
                action.text,
                Some(&owner),
                action.due,
                Some(is_user),
                if is_user { 4 } else { 3 },
                vec![cited],
                Some(attribution),
            );
            if let Some(status) = action.status {
                let mut saved = ActionState::new(status);
                saved.updated_at = whole_seconds(started + Duration::minutes(demo.minutes + 30));
                state.actions.insert(item.id.clone(), saved);
            }
            item
        })
        .collect();
    let decisions: Vec<Decision> = demo
        .decisions
        .iter()
        .map(|(index, text)| {
            let cited = citation(*index);
            let mut decision = Decision::new(text, vec![cited.clone()]);
            decision.attribution = Some(DecisionAttribution {
                speaker_id: cited.speaker.clone(),
                speaker_label: if cited.speaker == "me" {
                    "You".into()
                } else {
                    transcript.speaker_name(&cited.speaker)
                },
                identity: if cited.speaker == "me" {
                    SpeakerIdentity::User
                } else {
                    SpeakerIdentity::Other
                },
                quote: cited.excerpt.clone(),
            });
            decision
        })
        .collect();
    let outcomes = MeetingOutcomes {
        schema_version: OUTCOMES_SCHEMA_VERSION,
        transcript_revision: None,
        action_items: actions,
        decision_records: decisions,
        open_questions: demo.questions.iter().map(|q| q.to_string()).collect(),
    };
    library.save_outcomes(&meeting, &outcomes)?;
    if !state.actions.is_empty() {
        library.save_outcome_state(&meeting, &state)?;
    }

    let words = transcript.word_count();
    let mut summary = format!(
        "# {} — {}\n**Duration:** {} min · **App:** {} · **Words:** {} · **Template:** Meeting · **Model:** {}\n\n## TL;DR\n",
        demo.title,
        local.format("%B %-d, %Y at %-I:%M %p"),
        demo.minutes,
        demo.app,
        words,
        ENGINE
    );
    for (index, claim) in demo.tldr {
        let segment = &transcript.segments[*index];
        let name = if segment.speaker == "me" {
            "You".to_string()
        } else {
            transcript.speaker_name(&segment.speaker)
        };
        summary.push_str(&format!(
            "- **{name}:** {claim} — [{}]\n",
            crate::time::stamp(segment.start)
        ));
    }
    summary.push_str("\n## Key points\n");
    if demo.key_points.is_empty() {
        summary.push_str("None\n");
    }
    for point in demo.key_points {
        summary.push_str(&format!("- {point}\n"));
    }
    summary.push_str("\n## Decisions\n\n## Action items\n\n## Open questions\n");
    if demo.questions.is_empty() {
        summary.push_str("None\n");
    }
    for question in demo.questions {
        summary.push_str(&format!("- {question}\n"));
    }
    let summary =
        crate::actions::synchronize_summary(&summary, &outcomes.clone().prioritized(), true);
    library.save_summary(&meeting, &summary)?;
    if let Some(notes) = demo.notes {
        library.save_notes(&meeting, notes)?;
    }
    Ok(meeting)
}

fn seed_activity(library: &Library, clock: &Clock) -> Result<Vec<i64>> {
    for (app, title, from, to) in TODAY_BLOCKS {
        library.append_activity(
            app,
            title,
            clock.at(When::Ago(*from)),
            clock.at(When::Ago(*to)),
        )?;
    }
    for (days, app, title, from, to) in EARLIER_BLOCKS {
        let parse = |hhmm: &str| -> (u32, u32) {
            let (h, m) = hhmm.split_once(':').unwrap_or(("0", "0"));
            (h.parse().unwrap_or(0), m.parse().unwrap_or(0))
        };
        let ((fh, fm), (th, tm)) = (parse(from), parse(to));
        library.append_activity(
            app,
            title,
            clock.at(When::Day(*days, fh, fm)),
            clock.at(When::Day(*days, th, tm)),
        )?;
    }
    let mut ids = Vec::new();
    for shot in shots() {
        let id = library.record_screen_moment(&crate::timeline::NewScreenMoment {
            ts: clock.at(shot.when),
            app: shot.app.into(),
            window_title: shot.title.into(),
            trigger: "window_change".into(),
            path: String::new(),
            text: shot.text.into(),
            text_source: "accessibility".into(),
            source_url: String::new(),
            document_name: shot.title.split(" - ").next().unwrap_or(shot.title).into(),
            meeting_id: shot.meeting,
            privacy_redactions: 0,
        })?;
        if let Some(note) = shot.note {
            library.save_moment(id, note)?;
        }
        ids.push(id);
    }
    Ok(ids)
}

fn seed_chats(library: &Library, clock: &Clock, shot_ids: &[i64]) -> Result<()> {
    let message =
        |id: u128, role: ChatRole, text: String, activity: Vec<ChatActivity>, at: DateTime<Utc>| {
            ChatMessage {
                id: Uuid::from_u128(id),
                role,
                text,
                activity,
                created_at: Some(whole_seconds(at)),
            }
        };
    let tool = |id: u128, tool: &str, icon: &str, text: &str| ChatActivity {
        id: Uuid::from_u128(id),
        tool: tool.into(),
        icon: icon.into(),
        text: text.into(),
        done: true,
    };
    let shoot = crate::ids::uuid_upper(&STUDIO_SHOOT);
    let northwind = crate::ids::uuid_upper(&mid(24));
    let laptops = crate::ids::uuid_upper(&mid(21));
    let budget_shot = shot_ids.get(2).copied().unwrap_or(3);
    let now = clock.anchor;
    let conversations = [
        Conversation {
            id: Uuid::from_u128(0xbbbbbbb1_0000_4000_8000_000000000001),
            title: "Holiday shoot plan".into(),
            created_at: whole_seconds(now - Duration::minutes(9)),
            updated_at: whole_seconds(now - Duration::minutes(2)),
            messages: vec![
                message(
                    0xbbbbbbb1_0000_4000_8000_000000000101,
                    ChatRole::User,
                    "What did we decide for the holiday shoot?".into(),
                    vec![],
                    now - Duration::minutes(9),
                ),
                message(
                    0xbbbbbbb1_0000_4000_8000_000000000102,
                    ChatRole::Assistant,
                    format!(
                        "Everything is shot on phones, stills and video, for one consistent look [meeting:{shoot}@0:12]. \
                         Footage moves over the shared drive for selects and on the external SSD for full shoot days [meeting:{shoot}@1:22].\n\n\
                         You're booking the photo studio for Thursday morning [meeting:{shoot}@0:26], \
                         and Maya is sending the Figma shot list to the crew tonight [meeting:{shoot}@0:38]."
                    ),
                    vec![
                        tool(
                            0xbbbbbbb1_0000_4000_8000_000000000201,
                            "search_meetings",
                            "search",
                            "searched meetings for “holiday shoot”",
                        ),
                        tool(
                            0xbbbbbbb1_0000_4000_8000_000000000202,
                            "get_meeting",
                            "file-text",
                            "read “Holiday shoot planning”",
                        ),
                    ],
                    now - Duration::minutes(8),
                ),
            ],
        },
        Conversation {
            id: Uuid::from_u128(0xbbbbbbb2_0000_4000_8000_000000000002),
            title: "Northwind captions".into(),
            created_at: whole_seconds(now - Duration::hours(26)),
            updated_at: whole_seconds(now - Duration::hours(26)),
            messages: vec![
                message(
                    0xbbbbbbb2_0000_4000_8000_000000000101,
                    ChatRole::User,
                    "What does Northwind need before the cut goes live?".into(),
                    vec![],
                    now - Duration::hours(26),
                ),
                message(
                    0xbbbbbbb2_0000_4000_8000_000000000102,
                    ChatRole::Assistant,
                    format!(
                        "Captions. Their legal team won't put the cut on the site without them [meeting:{northwind}@0:00]. \
                         You promised the captioned cut this week [meeting:{northwind}@0:15], and they asked for a quote on three social cut-downs \
                         [meeting:{northwind}@0:30]."
                    ),
                    vec![
                        tool(
                            0xbbbbbbb2_0000_4000_8000_000000000201,
                            "search_meetings",
                            "search",
                            "searched meetings for “Northwind”",
                        ),
                        tool(
                            0xbbbbbbb2_0000_4000_8000_000000000202,
                            "get_meeting",
                            "file-text",
                            "read “Client call – Northwind”",
                        ),
                    ],
                    now - Duration::hours(26),
                ),
            ],
        },
        Conversation {
            id: Uuid::from_u128(0xbbbbbbb3_0000_4000_8000_000000000003),
            title: "Laptop refresh budget".into(),
            created_at: whole_seconds(now - Duration::minutes(40)),
            updated_at: whole_seconds(now - Duration::minutes(38)),
            messages: vec![
                message(
                    0xbbbbbbb3_0000_4000_8000_000000000101,
                    ChatRole::User,
                    "Which laptops are we buying, and is it in the budget?".into(),
                    vec![],
                    now - Duration::minutes(40),
                ),
                message(
                    0xbbbbbbb3_0000_4000_8000_000000000102,
                    ChatRole::Assistant,
                    format!(
                        "Workstation laptops for both editors and light laptops for sales [meeting:{laptops}@0:12]. \
                         The studio budget sheet already lists two workstation laptops, three light laptops and an extended warranty on all [screen:{budget_shot}]. \
                         The order waits for the vendor's business quote, which you're requesting by Thursday [meeting:{laptops}@0:26]."
                    ),
                    vec![
                        tool(
                            0xbbbbbbb3_0000_4000_8000_000000000201,
                            "search_meetings",
                            "search",
                            "searched meetings for “laptop”",
                        ),
                        tool(
                            0xbbbbbbb3_0000_4000_8000_000000000202,
                            "search_screen",
                            "monitor",
                            "searched your screen for “budget”",
                        ),
                    ],
                    now - Duration::minutes(39),
                ),
            ],
        },
    ];
    for conversation in &conversations {
        library.save_conversation(conversation)?;
    }
    Ok(())
}

fn seed_people_and_projects(paths: &LibraryPaths, clock: &Clock) -> Result<()> {
    let curation = PeopleCuration {
        version: 1,
        names: [(
            crate::people::person_id_for_name("Priya Nair"),
            "Priya Nair".to_string(),
        )]
        .into_iter()
        .collect(),
        merges: Vec::new(),
        hidden: vec![HiddenPerson {
            id: crate::people::person_id_for_name("Lena Fischer"),
            name: "Lena Fischer".into(),
        }],
    };
    write_json(&paths.people_dir().join("curation.json"), &curation)?;
    let created = whole_seconds(clock.at(When::Day(12, 9, 0)));
    let laptop = TrackedProject {
        id: Uuid::from_u128(0xccccccc1_0000_4000_8000_000000000001),
        name: "Laptop refresh".into(),
        other_names: vec!["Laptop".into()],
        created_at: created,
    };
    let holiday = TrackedProject {
        id: Uuid::from_u128(0xccccccc2_0000_4000_8000_000000000002),
        name: "Holiday shoot".into(),
        other_names: vec!["Holiday campaign".into()],
        created_at: created,
    };
    let projects = ProjectCuration {
        version: 1,
        tracked: vec![laptop.clone(), holiday],
        hidden_names: vec!["weekly".into()],
    };
    write_json(&paths.projects_dir().join("tracked.json"), &projects)?;
    let date = |id: Uuid| {
        clock.at(match id {
            id if id == mid(21) => When::Ago(102),
            id if id == mid(31) => When::Day(8, 13, 30),
            _ => When::Day(14, 10, 30),
        })
    };
    let point = |text: &str, id: Uuid, title: &str| ProjectPoint {
        text: text.into(),
        meeting_id: Some(crate::ids::uuid_upper(&id)),
        meeting_title: Some(title.into()),
        meeting_date: Some(
            crate::time::local_day(date(id))
                .format("%Y-%m-%d")
                .to_string(),
        ),
    };
    let summary = ProjectSummary {
        project_id: format!("tracked:{}", crate::ids::uuid_upper(&laptop.id)),
        overview: "The editors move to workstation laptops and sales to light laptops; the order waits for the vendor's business quote, due Thursday.".into(),
        points: vec![
            point("Exports take forty minutes on the old laptops, which drives the refresh.", mid(21), "Laptop refresh planning"),
            point("Three of the old laptops are out of warranty.", mid(31), "Equipment budget review"),
            point("The Q4 budget approved the refresh in principle, sized after the trade-in quote.", mid(36), "Budget review Q4"),
        ],
        open_questions: vec!["Does sales need anything more than a light laptop?".into()],
        meeting_ids: [mid(21), mid(31), mid(36)].iter().map(crate::ids::uuid_upper).collect(),
        evidence_fingerprint: crate::ids::fnv_hex("demo-laptop-refresh"),
        generated_at: whole_seconds(clock.anchor - Duration::minutes(30)),
        engine_name: ENGINE.into(),
        location: "on this PC".into(),
    };
    crate::projects::write_project_summaries(
        &paths.projects_dir().join("summaries.json"),
        vec![summary],
    )?;
    Ok(())
}

fn seed_journals(
    library: &Library,
    clock: &Clock,
    meetings: &[Meeting],
    shot_ids: &[i64],
) -> Result<()> {
    let today = clock.today();
    let today_summary = "### At a glance\n\
- The holiday shoot is locked: phones only, Thursday morning at the photo studio.\n\
- The editors move to workstation laptops once the vendor's quote is in.\n\
- The Northwind holiday cut wraps today.\n\n\
### Tasks\n\
- **Holiday shoot planning** — In progress. Settled the plan with Maya: phones for stills and video, selects over the shared drive, three vertical cuts for social.\n\
- **Laptop refresh** — In progress. Compared business laptops and put two workstation and three light laptops in the studio budget. {shot2} {shot3}\n\
- **Northwind holiday cut** — In progress. Edited the holiday cut in DaVinci Resolve with the captions track on. {shot6}\n\
- **Northwind pitch deck** — Completed. Finished the three-hero-shot story for the pitch deck. {shot1}\n\n\
### Decisions and next steps\n\
- Decision: Shoot stills and video on phones for one consistent look.\n\
- Decision: The 4K monitors wait until next quarter.\n\
- Blocker: 4K exports still crawl on the old laptops.\n\
- Next — Holiday shoot planning: Book the photo studio for Thursday morning.\n\
- Next — Laptop refresh: Request the business quote by Thursday.\n";
    let yesterday_summary = "### At a glance\n\
- The podcast trailer becomes a sixty-second cut that ships Friday.\n\
- The Globex demo presentation went out; Globex asked for the slides.\n\n\
### Tasks\n\
- **Podcast trailer** — In progress. Agreed the sixty-second cut and the music mix with John. \n\
- **Globex demo presentation** — Completed. Presented the case studies and launch timeline. {shot7}\n\
- **Holiday campaign deck** — In progress. Drafted the campaign deck and the shot list.\n\n\
### Decisions and next steps\n\
- Decision: The trailer reuses the episode artwork.\n\
- Next — Globex demo presentation: Share the slides with the Globex team.\n";
    for (day_offset, summary) in [(1i64, yesterday_summary), (0, today_summary)] {
        let day = today - Duration::days(day_offset);
        let mut summary = summary.to_string();
        for (index, id) in shot_ids.iter().enumerate() {
            summary = summary.replace(&format!("{{shot{}}}", index + 1), &format!("[screen:{id}]"));
        }
        let markdown = render_journal(library, day, &summary, meetings)?;
        let evidence = library.latest_evidence_at(day)?;
        let meta = DigestMeta {
            generated_at: whole_seconds(Utc::now()),
            evidence_latest_at: evidence,
            engine: Some(ENGINE.into()),
            ..DigestMeta::default()
        };
        library.save_digest(day, &markdown, &meta)?;
    }
    Ok(())
}

/// The journal layout `DayDigestEvidence.renderDocument` writes.
fn render_journal(
    library: &Library,
    day: chrono::NaiveDate,
    summary: &str,
    meetings: &[Meeting],
) -> Result<String> {
    let clock = |at: DateTime<Utc>| at.with_timezone(&Local).format("%H:%M").to_string();
    let (start, end) = crate::time::local_day_bounds(day);
    let mut sections = vec![format!("## Day summary\n\n{}", summary.trim_end())];

    let day_meetings: Vec<&Meeting> = meetings
        .iter()
        .filter(|m| crate::time::local_day(m.started_at) == day)
        .collect();
    let mut ordered = day_meetings.clone();
    ordered.sort_by_key(|m| m.started_at);
    let meeting_lines: Vec<String> = ordered
        .iter()
        .map(|m| {
            let tldr = library
                .summary(m)
                .ok()
                .flatten()
                .and_then(|s| {
                    s.split("## TL;DR")
                        .nth(1)
                        .map(|rest| rest.split("\n## ").next().unwrap_or("").to_string())
                })
                .unwrap_or_default();
            // The recap's claims without bullets, speakers or stamps.
            let tldr = tldr
                .lines()
                .filter_map(|line| {
                    let line = line.trim().strip_prefix("- ")?;
                    let claim = line.split_once(":** ").map_or(line, |(_, claim)| claim);
                    Some(
                        claim
                            .split(" — [")
                            .next()
                            .unwrap_or(claim)
                            .trim()
                            .to_string(),
                    )
                })
                .collect::<Vec<_>>()
                .join(" ");
            format!(
                "### {} — {}\n- App: {}\n- Duration: {}\n- Source summary: {}",
                clock(m.started_at),
                m.title,
                m.app_name,
                journal_duration(m.duration_seconds()),
                tldr
            )
        })
        .collect();
    sections.push(format!(
        "## Meetings\n\n{}",
        if meeting_lines.is_empty() {
            "_None._".to_string()
        } else {
            meeting_lines.join("\n\n")
        }
    ));

    let blocks = library.activity_blocks(start, end)?;
    let mut totals: std::collections::BTreeMap<&str, f64> = std::collections::BTreeMap::new();
    for block in &blocks {
        *totals.entry(block.app.as_str()).or_default() += block.duration_seconds();
    }
    let mut totals: Vec<(&str, f64)> = totals.into_iter().collect();
    totals.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.0.cmp(b.0))
    });
    let mut table = vec![
        "| App | Tracked time |".to_string(),
        "| --- | ---: |".to_string(),
    ];
    table.extend(
        totals
            .iter()
            .map(|(app, seconds)| format!("| {app} | {} |", journal_duration(*seconds))),
    );
    sections.push(format!("## Time allocation\n\n{}", table.join("\n")));

    let moments = library.screen_moments(start, end)?;
    let mut log: Vec<(DateTime<Utc>, u8, String)> = Vec::new();
    for block in &blocks {
        let mut line = format!(
            "- **{}–{}** — **{}**",
            clock(block.start),
            clock(block.end),
            block.app
        );
        if !block.title.is_empty() {
            line.push_str(&format!(" — {}", block.title));
        }
        for moment in moments
            .iter()
            .filter(|m| m.ts >= block.start && m.ts < block.end)
        {
            line.push_str(&format!(
                "\n  - [screen:{}], {}: {}",
                moment.id,
                clock(moment.ts),
                moment.text.clone().unwrap_or_default()
            ));
        }
        log.push((block.start, 1, line));
    }
    for meeting in &ordered {
        log.push((
            meeting.started_at,
            0,
            format!(
                "- **{}–{}** — **Meeting** — {} ({})",
                clock(meeting.started_at),
                clock(meeting.ended_at.unwrap_or(meeting.started_at)),
                meeting.title,
                meeting.app_name
            ),
        ));
    }
    log.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    sections.push(format!(
        "## Full activity log\n\n{}",
        log.into_iter()
            .map(|(_, _, line)| line)
            .collect::<Vec<_>>()
            .join("\n")
    ));
    Ok(sections.join("\n\n") + "\n")
}

/// "2h 5m", "25m", "<1m" (`DayDigestEvidence.duration`).
fn journal_duration(seconds: f64) -> String {
    let minutes = (seconds.round() as i64 / 60).max(0);
    if minutes == 0 {
        "<1m".into()
    } else if minutes >= 60 {
        format!("{}h {}m", minutes / 60, minutes % 60)
    } else {
        format!("{minutes}m")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_a_library_it_did_not_create() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("settings.json"), "{}").unwrap();
        let err = seed(&LibraryPaths::new(dir.path()), Utc::now()).unwrap_err();
        assert!(err.to_string().contains("Refusing"), "{err}");
    }

    #[test]
    fn seeds_and_reseeds_a_demo_library() {
        let dir = tempfile::tempdir().unwrap();
        let paths = LibraryPaths::new(dir.path().join("lib"));
        seed(&paths, Utc::now()).unwrap();
        seed(&paths, Utc::now()).unwrap();
        let library = Library::open(paths).unwrap();
        assert_eq!(library.list_meetings().unwrap().len(), 17);
        assert_eq!(library.conversations().unwrap().len(), 3);
    }

    #[test]
    fn mid_ids_match_the_python_seeder() {
        assert_eq!(mid(21).to_string(), "00000021-0000-4000-8000-000000000021");
    }
}
