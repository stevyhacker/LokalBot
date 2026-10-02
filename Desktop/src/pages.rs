use crate::*;

fn scroll(id: &'static str) -> Stateful<Div> {
    column()
        .id(id)
        .flex_1()
        .h_full()
        .overflow_y_scroll()
        .px(px(32.))
        .py(px(27.))
        .gap(px(23.))
}
fn date(at: i64, format: &str) -> String {
    chrono::DateTime::from_timestamp(at, 0)
        .map(|d| d.with_timezone(&chrono::Local).format(format).to_string())
        .unwrap_or_default()
}
fn empty(title: &str, body: &str) -> AnyElement {
    panel()
        .p(px(28.))
        .gap(px(12.))
        .child(heading(title.to_owned(), 18.))
        .child(label(body.to_owned(), 13., MUTED).line_height(px(23.)))
        .into_any_element()
}
fn preference(id: &'static str, title: &str, detail: &str, enabled: bool) -> Stateful<Div> {
    row()
        .id(id)
        .py(px(14.))
        .border_b_1()
        .border_color(rgb(BORDER))
        .cursor_pointer()
        .child(
            column()
                .flex_1()
                .gap(px(6.))
                .child(heading(title.to_owned(), 13.))
                .child(label(detail.to_owned(), 11., MUTED)),
        )
        .child(
            row()
                .w(px(35.))
                .h(px(20.))
                .p(px(3.))
                .rounded_full()
                .bg(rgb(if enabled { 0x4baa94 } else { 0x3b4653 }))
                .when(enabled, |d| d.justify_end())
                .child(div().size(px(14.)).rounded_full().bg(rgb(TEXT))),
        )
}

impl AppView {
    pub fn today(&self, cx: &mut Context<Self>) -> AnyElement {
        let day = services::today();
        let (start, end) = services::day_bounds(&day).unwrap_or((0, i64::MAX));
        let meetings = self
            .meetings
            .iter()
            .filter(|m| m.started_at >= start && m.started_at < end)
            .collect::<Vec<_>>();
        let actions = self
            .meetings
            .iter()
            .flat_map(|m| {
                m.summary.as_ref().into_iter().flat_map(|s| {
                    s.actions
                        .iter()
                        .filter(|a| !a.done)
                        .map(|a| (m.id.clone(), a.clone()))
                })
            })
            .collect::<Vec<_>>();
        let activity = self
            .activity
            .iter()
            .filter(|a| a.start >= start && a.start < end)
            .map(|a| a.end - a.start)
            .sum::<i64>();
        let stats = row().py(px(15.)).gap(px(35.)).children(
            [
                (
                    format!("{}h {}m", activity / 3600, activity % 3600 / 60),
                    "Tracked activity",
                ),
                (meetings.len().to_string(), "Meetings"),
                (self.moments.len().to_string(), "Retained moments"),
                (actions.len().to_string(), "Open actions"),
            ]
            .into_iter()
            .map(|(value, title)| {
                column()
                    .flex_1()
                    .gap(px(12.))
                    .child(label(title, 11., MUTED))
                    .child(heading(value, 27.))
            }),
        );
        let digest = self.library.digest(&day).ok().flatten();
        let digest_card=panel().p(px(23.)).gap(px(18.)).child(row().child(icon(IconName::Sparkles,ACCENT)).child(heading("Your day so far",15.)).child(div().flex_1()).child(button("write-digest",if digest.is_some(){"Update digest"}else{"Write digest"},IconName::Sparkles,false).on_click(cx.listener(move|this,_,_,cx|{let day=day.clone();this.spawn("Day digest",move|lib|{services::digest(lib,&day)?;Ok(Output::Refresh)},cx);}))))
            .child(label(digest.map(|d|d.text).unwrap_or_else(||"Write a digest from the meetings and activity stored in your library. The selected inference destination is shown below.".into()),14.,0xc8d0da).line_height(px(24.))).child(label(self.inference_label(),10.,MUTED));
        let mut action_card = panel().p(px(22.)).child(section_header(
            "Next actions",
            IconName::ListChecks,
            "Click to complete",
        ));
        if actions.is_empty() {
            action_card = action_card.child(label(
                "No open actions. Write meeting notes to extract source-linked actions.",
                13.,
                MUTED,
            ));
        }
        action_card = action_card.children(
            actions
                .into_iter()
                .take(6)
                .map(|(meeting, a)| self.action_row(meeting, a, cx)),
        );
        let recent = column()
            .gap(px(12.))
            .child(section_header("Recent meetings", IconName::Video, ""))
            .children(self.meetings.iter().take(5).map(|m| {
                let id = m.id.clone();
                row()
                    .id(format!("recent-{id}"))
                    .py(px(14.))
                    .border_b_1()
                    .border_color(rgb(BORDER))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.select(id.clone(), 0, window, cx)
                    }))
                    .child(icon(IconName::Video, MUTED))
                    .child(
                        column()
                            .flex_1()
                            .gap(px(5.))
                            .child(heading(m.title.clone(), 13.))
                            .child(label(
                                format!(
                                    "{} · {} · {}",
                                    m.app,
                                    date(m.started_at, "%H:%M"),
                                    timecode(m.duration)
                                ),
                                11.,
                                MUTED,
                            )),
                    )
                    .child(badge(
                        if m.summary.is_some() {
                            "Notes ready"
                        } else if m.segments.is_empty() {
                            "Needs transcription"
                        } else {
                            "Transcript ready"
                        },
                        m.summary.is_some(),
                    ))
                    .into_any_element()
            }));
        let moments = column()
            .w(px(310.))
            .flex_shrink_0()
            .gap(px(15.))
            .child(section_header(
                "Picked up along the way",
                IconName::Monitor,
                "",
            ))
            .children(self.moments.iter().take(4).map(|m| {
                let id = m.id.clone();
                panel()
                    .id(format!("today-moment-{id}"))
                    .p(px(16.))
                    .gap(px(10.))
                    .child(
                        row()
                            .child(icon(IconName::FileText, MUTED))
                            .child(label(m.app.clone(), 11., MUTED))
                            .child(div().flex_1())
                            .child(label(date(m.created_at, "%H:%M"), 10., MUTED)),
                    )
                    .child(heading(m.title.clone(), 13.))
                    .child(label(m.text.clone(), 11., MUTED).line_height(px(19.)))
                    .into_any_element()
            }));
        scroll("today-scroll")
            .child(
                row()
                    .items_start()
                    .child(page_header(
                        "Today",
                        &chrono::Local::now().format("%A, %B %-d, %Y").to_string(),
                    ))
                    .child(div().flex_1())
                    .child(
                        button(
                            "import-today",
                            "Import transcript",
                            IconName::FileText,
                            false,
                        )
                        .on_click(
                            cx.listener(|this, _, window, cx| this.import(false, window, cx)),
                        ),
                    )
                    .child(
                        button("ask-today", "Ask about today", IconName::Sparkles, false).on_click(
                            cx.listener(|this, _, window, cx| this.navigate(Page::Ask, window, cx)),
                        ),
                    ),
            )
            .child(
                row()
                    .h(px(65.))
                    .flex_shrink_0()
                    .px(px(18.))
                    .rounded(px(9.))
                    .bg(rgb(ACCENT_BG))
                    .border_1()
                    .border_color(rgb(0x23423a))
                    .child(icon(IconName::Mic, ACCENT))
                    .child(
                        column()
                            .flex_1()
                            .gap(px(5.))
                            .child(heading(
                                if self.recording.is_some() {
                                    "Recording microphone"
                                } else {
                                    "Ready when you are"
                                },
                                13.,
                            ))
                            .child(label(
                                self.recording
                                    .as_ref()
                                    .map(|r| {
                                        format!(
                                            "{} elapsed · audio checkpoints saved locally",
                                            timecode(r.started.elapsed().as_secs_f64())
                                        )
                                    })
                                    .unwrap_or_else(|| {
                                        "Record a meeting, or import audio and transcripts.".into()
                                    }),
                                11.,
                                MUTED,
                            )),
                    )
                    .child(
                        button(
                            "record",
                            if self.recording.is_some() {
                                "Stop and save"
                            } else {
                                "Record now"
                            },
                            IconName::Mic,
                            true,
                        )
                        .on_click(cx.listener(|this, _, _, cx| this.record(false, cx))),
                    ),
            )
            .child(stats)
            .child(
                row()
                    .items_start()
                    .gap(px(24.))
                    .child(
                        column()
                            .flex_1()
                            .gap(px(22.))
                            .child(digest_card)
                            .child(action_card)
                            .child(recent),
                    )
                    .child(moments),
            )
            .into_any_element()
    }

    pub fn meetings_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let matches = self
            .library
            .search(&self.query, 100)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|e| e.meeting_id)
            .collect::<std::collections::HashSet<_>>();
        let list = column()
            .w(px(295.))
            .h_full()
            .flex_shrink_0()
            .bg(rgb(0x14181e))
            .border_r_1()
            .border_color(rgb(BORDER))
            .child(
                column()
                    .p(px(16.))
                    .gap(px(14.))
                    .child(
                        Input::new(&self.search)
                            .prefix(icon(IconName::Search, MUTED))
                            .aria_label("Search meetings"),
                    )
                    .child(
                        row()
                            .child(badge("All meetings", true))
                            .child(div().flex_1())
                            .child(label(self.meetings.len().to_string(), 11., MUTED)),
                    ),
            )
            .child(
                column()
                    .id("meeting-list")
                    .overflow_y_scroll()
                    .px(px(10.))
                    .gap(px(6.))
                    .children(
                        self.meetings
                            .iter()
                            .filter(|m| {
                                self.query.is_empty()
                                    || m.title.to_lowercase().contains(&self.query.to_lowercase())
                                    || matches.contains(&m.id)
                            })
                            .map(|m| {
                                let id = m.id.clone();
                                column()
                                    .id(format!("meeting-{id}"))
                                    .px(px(12.))
                                    .py(px(16.))
                                    .gap(px(9.))
                                    .rounded(px(8.))
                                    .cursor_pointer()
                                    .bg(rgb(if self.selected.as_ref() == Some(&m.id) {
                                        0x25322f
                                    } else {
                                        0x14181e
                                    }))
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.select(id.clone(), 0, window, cx)
                                    }))
                                    .child(heading(m.title.clone(), 12.))
                                    .child(label(
                                        format!("{} · {}", m.app, date(m.started_at, "%a %H:%M")),
                                        10.,
                                        MUTED,
                                    ))
                                    .child(
                                        row()
                                            .child(label(timecode(m.duration), 10., MUTED))
                                            .child(div().flex_1())
                                            .child(label(
                                                if m.summary.is_some() {
                                                    "Notes ready"
                                                } else if m.segments.is_empty() {
                                                    "Audio"
                                                } else {
                                                    "Transcript"
                                                },
                                                10.,
                                                ACCENT,
                                            )),
                                    )
                                    .into_any_element()
                            }),
                    ),
            );
        let Some(m) = self.current().cloned() else {
            return row().items_start().gap(px(0.)).flex_1().h_full().child(list).child(scroll("empty-meetings").child(page_header("Meetings","Your conversations, notes, and next actions.")).child(empty("Start your library","Import a transcript or audio file, or record your microphone. New installs contain no demo records.")).child(row().child(button("import-empty","Import transcript",IconName::FileText,true).on_click(cx.listener(|this,_,window,cx|this.import(false,window,cx)))).child(button("audio-empty","Import audio",IconName::Mic,false).on_click(cx.listener(|this,_,window,cx|this.import(true,window,cx)))))).into_any_element();
        };
        let id = m.id.clone();
        let summary_id = id.clone();
        let transcribe_id = id.clone();
        let export_id = id.clone();
        let delete_id = id.clone();
        let mut detail = scroll("meeting-detail")
            .px(px(28.))
            .gap(px(20.))
            .child(
                row()
                    .items_start()
                    .child(page_header(
                        &m.title,
                        &format!(
                            "{} · {} · {}",
                            date(m.started_at, "%A, %B %-d · %H:%M"),
                            m.app,
                            timecode(m.duration)
                        ),
                    ))
                    .child(div().flex_1())
                    .child(
                        button(
                            "write-notes",
                            if m.summary.is_some() {
                                "Refresh notes"
                            } else {
                                "Write notes"
                            },
                            IconName::Sparkles,
                            true,
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            let id = summary_id.clone();
                            this.spawn(
                                "Meeting notes",
                                move |lib| {
                                    services::summarize(lib, &id)?;
                                    Ok(Output::Refresh)
                                },
                                cx,
                            );
                        })),
                    )
                    .child(
                        button("export-meeting", "Export", IconName::FileText, false).on_click(
                            cx.listener(move |this, _, window, cx| {
                                this.export(export_id.clone(), window, cx)
                            }),
                        ),
                    ),
            )
            .child(
                row()
                    .child(label(
                        if m.people.is_empty() {
                            "Speakers are unconfirmed".into()
                        } else {
                            m.people.join(", ")
                        },
                        11.,
                        MUTED,
                    ))
                    .child(div().flex_1())
                    .child(
                        button("import-audio", "Import audio", IconName::Mic, false).on_click(
                            cx.listener(|this, _, window, cx| this.import(true, window, cx)),
                        ),
                    )
                    .child(
                        button(
                            "import-transcript",
                            "Import transcript",
                            IconName::FileText,
                            false,
                        )
                        .on_click(
                            cx.listener(|this, _, window, cx| this.import(false, window, cx)),
                        ),
                    ),
            );
        if !m.media.is_empty() {
            let media = m.clone();
            let waveform = audio::envelope(&self.library, &m).unwrap_or_default();
            let mut wave = row().gap(px(3.)).h(px(42.)).flex_1().overflow_hidden();
            for level in waveform {
                wave = wave.child(
                    div()
                        .w(px(4.))
                        .h(px(6. + level * 34.))
                        .rounded(px(2.))
                        .bg(rgb(ACCENT)),
                );
            }
            detail = detail.child(
                panel()
                    .p(px(16.))
                    .gap(px(12.))
                    .child(
                        row()
                            .child(
                                button(
                                    "play",
                                    if self.playback.is_some() {
                                        "Pause"
                                    } else {
                                        "Play"
                                    },
                                    if self.playback.is_some() {
                                        IconName::Pause
                                    } else {
                                        IconName::Play
                                    },
                                    false,
                                )
                                .on_click(cx.listener(
                                    move |this, _, _, cx| {
                                        if this.playback.take().is_none() {
                                            match audio::Playback::start(
                                                &this.library,
                                                &media,
                                                this.seek,
                                            ) {
                                                Ok(p) => this.playback = Some(p),
                                                Err(e) => this.error = e.to_string(),
                                            }
                                        }
                                        cx.notify();
                                    },
                                )),
                            )
                            .child(wave)
                            .child(label(timecode(self.seek), 11., MUTED)),
                    )
                    .child(
                        row()
                            .child(label("Original audio · stored locally", 10., MUTED))
                            .child(div().flex_1())
                            .child(
                                button("transcribe", "Transcribe", IconName::FileText, false)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let id = transcribe_id.clone();
                                        this.spawn(
                                            "Transcription",
                                            move |lib| {
                                                services::transcribe_meeting(lib, &id)?;
                                                Ok(Output::Refresh)
                                            },
                                            cx,
                                        );
                                    })),
                            ),
                    ),
            );
        } else {
            detail = detail.child(label("Transcript import · no audio recording", 11., MUTED));
        }
        let mut tabs = row()
            .gap(px(25.))
            .h(px(42.))
            .border_b_1()
            .border_color(rgb(BORDER));
        for (index, title) in ["Summary", "Transcript", "Notes"].into_iter().enumerate() {
            tabs = tabs.child(
                row()
                    .id(("meeting-tab", index))
                    .h_full()
                    .border_b(px(2.))
                    .border_color(rgb(if self.tab == index { ACCENT } else { BG }))
                    .text_color(rgb(if self.tab == index { ACCENT } else { MUTED }))
                    .text_size(px(12.))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.tab = index;
                        cx.notify();
                    }))
                    .child(title),
            );
        }
        detail = detail.child(tabs);
        match self.tab {
            1 => {
                if m.segments.is_empty() {
                    detail = detail.child(empty(
                        "No transcript yet",
                        "Transcribe the audio to make this meeting searchable.",
                    ));
                }
                for s in &m.segments {
                    let seek = s.start;
                    let media = m.clone();
                    detail = detail.child(
                        row()
                            .id(format!("transcript-{}", s.id))
                            .items_start()
                            .gap(px(15.))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.seek = seek;
                                if this.playback.is_some() {
                                    this.playback =
                                        audio::Playback::start(&this.library, &media, seek).ok();
                                }
                                cx.notify();
                            }))
                            .child(label(timecode(s.start), 10., ACCENT).w(px(45.)))
                            .child(avatar(
                                &s.speaker.chars().take(2).collect::<String>(),
                                0x3e5673,
                                28.,
                            ))
                            .child(
                                column()
                                    .flex_1()
                                    .gap(px(8.))
                                    .child(heading(s.speaker.clone(), 12.))
                                    .child(
                                        label(s.text.clone(), 13., 0xc8d0da).line_height(px(23.)),
                                    ),
                            ),
                    );
                }
            }
            2 => {
                let note_id = id.clone();
                detail = detail.child(
                    panel()
                        .p(px(22.))
                        .gap(px(18.))
                        .child(heading("Your notes", 15.))
                        .child(
                            Textarea::new(&self.notes)
                                .h(px(250.))
                                .aria_label("Meeting notes"),
                        )
                        .child(
                            button("save-notes", "Save notes", IconName::Check, true).on_click(
                                cx.listener(move |this, _, _, cx| {
                                    let result = (|| {
                                        let mut m = this.library.meeting(&note_id)?;
                                        m.notes = this.notes.read(cx).value().to_string();
                                        this.library.save_meeting(&m)
                                    })();
                                    this.show_result(result, "Notes saved", cx);
                                }),
                            ),
                        ),
                );
            }
            _ => {
                if let Some(summary) = &m.summary {
                    detail = detail.child(
                        column()
                            .gap(px(16.))
                            .child(section_header("Overview", IconName::FileText, ""))
                            .child(
                                label(summary.overview.clone(), 14., 0xc8d0da).line_height(px(24.)),
                            ),
                    );
                    let decisions = panel()
                        .p(px(20.))
                        .gap(px(13.))
                        .child(section_header(
                            "Decisions",
                            IconName::Check,
                            &format!("{} decisions", summary.decisions.len()),
                        ))
                        .children(summary.decisions.iter().map(|d| {
                            let source = d.source.clone();
                            let text = d.text.clone();
                            row()
                                .id(format!("decision-{source}"))
                                .items_start()
                                .cursor_pointer()
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.tab = 1;
                                    if let Ok(e) = this.library.evidence(&source) {
                                        this.seek = e.start;
                                    }
                                    cx.notify();
                                }))
                                .child(icon(IconName::Check, ACCENT))
                                .child(label(text, 12., TEXT).flex_1())
                                .child(label("Source ↗", 10., ACCENT))
                                .into_any_element()
                        }));
                    detail = detail.child(decisions).child(
                        column()
                            .child(section_header(
                                "Action items",
                                IconName::ListChecks,
                                "Click to complete",
                            ))
                            .children(
                                summary
                                    .actions
                                    .iter()
                                    .cloned()
                                    .map(|a| self.action_row(id.clone(), a, cx)),
                            ),
                    );
                    if !summary.questions.is_empty() {
                        detail = detail.child(
                            panel()
                                .p(px(20.))
                                .gap(px(12.))
                                .child(heading("Open questions", 14.))
                                .children(
                                    summary
                                        .questions
                                        .iter()
                                        .map(|q| label(q.clone(), 13., MUTED)),
                                ),
                        );
                    }
                } else {
                    detail=detail.child(empty("Write source-linked meeting notes","Generate an overview, decisions, and actions from this transcript using your selected model."));
                }
            }
        }
        for warning in &m.warnings {
            detail = detail.child(label(warning.clone(), 12., 0xe99186));
        }
        if self.delete_confirm {
            detail = detail.child(
                panel()
                    .p(px(18.))
                    .gap(px(12.))
                    .child(label(
                        "Delete this meeting, its audio, and derived search evidence?",
                        13.,
                        TEXT,
                    ))
                    .child(
                        row()
                            .child(
                                button("confirm-delete", "Delete meeting", IconName::Trash, false)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        let result = this.library.delete_meeting(&delete_id);
                                        this.delete_confirm = false;
                                        this.show_result(result, "Meeting deleted", cx);
                                    })),
                            )
                            .child(
                                button("cancel-delete", "Cancel", IconName::X, false).on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.delete_confirm = false;
                                        cx.notify();
                                    }),
                                ),
                            ),
                    ),
            );
        } else {
            detail = detail.child(
                button("delete-meeting", "Delete meeting", IconName::Trash, false).on_click(
                    cx.listener(|this, _, _, cx| {
                        this.delete_confirm = true;
                        cx.notify();
                    }),
                ),
            );
        }
        row()
            .items_start()
            .gap(px(0.))
            .h_full()
            .flex_1()
            .child(list)
            .child(detail)
            .into_any_element()
    }

    pub fn timeline(&self, cx: &mut Context<Self>) -> AnyElement {
        let activities = column()
            .w(px(270.))
            .flex_shrink_0()
            .gap(px(18.))
            .child(section_header("Activity", IconName::Clock, ""))
            .children(self.activity.iter().take(18).map(|a| {
                column()
                    .pl(px(15.))
                    .py(px(10.))
                    .border_l(px(2.))
                    .border_color(rgb(BORDER))
                    .gap(px(7.))
                    .child(label(date(a.start, "%H:%M"), 10., ACCENT))
                    .child(heading(a.app.clone(), 12.))
                    .child(label(
                        if a.private {
                            "Private activity".into()
                        } else {
                            a.title.clone()
                        },
                        11.,
                        MUTED,
                    ))
                    .child(label(format!("{} min", (a.end - a.start) / 60), 10., MUTED))
            }));
        let moments = column()
            .flex_1()
            .gap(px(18.))
            .child(section_header(
                "Saved and retained moments",
                IconName::Bookmark,
                "Visible text · opt-in capture",
            ))
            .children(self.moments.iter().map(|m| {
                let id = m.id.clone();
                let saved = m.saved;
                panel()
                    .id(format!("moment-{id}"))
                    .p(px(20.))
                    .gap(px(13.))
                    .child(
                        row()
                            .child(icon(IconName::Monitor, MUTED))
                            .child(heading(m.title.clone(), 14.).flex_1())
                            .child(label(date(m.created_at, "%a %H:%M"), 10., MUTED)),
                    )
                    .child(label(m.text.clone(), 13., 0xc8d0da).line_height(px(22.)))
                    .child(
                        row()
                            .child(label(m.app.clone(), 10., MUTED))
                            .child(div().flex_1())
                            .child(badge(
                                if m.pixels.is_some() {
                                    "Encrypted pixels"
                                } else {
                                    "Text only"
                                },
                                false,
                            ))
                            .child(
                                button(
                                    format!("save-{id}"),
                                    if saved { "Unsave" } else { "Save moment" },
                                    IconName::Bookmark,
                                    false,
                                )
                                .on_click(cx.listener(
                                    move |this, _, _, cx| {
                                        let result = (|| {
                                            let mut moment = this
                                                .library
                                                .moments()?
                                                .into_iter()
                                                .find(|m| m.id == id)
                                                .ok_or_else(|| anyhow::anyhow!("Moment expired"))?;
                                            moment.saved = !saved;
                                            this.library.save_moment(&moment)
                                        })();
                                        this.show_result(result, "Moment updated", cx);
                                    },
                                )),
                            ),
                    )
                    .into_any_element()
            }));
        scroll("timeline-scroll").child(row().child(page_header("Timeline","Observed activity and the context you chose to keep.")).child(div().flex_1()).child(button("capture-screen","Capture focused text",IconName::Monitor,false).on_click(cx.listener(|this,_,_,cx|this.spawn("Screen capture",|lib|{platform::capture_screen(lib)?;Ok(Output::Refresh)},cx)))))
            .child(label(if self.settings.screen_text_enabled{"Accessible screen text is enabled. Focus, secure fields, and exclusions are checked before saving."}else{"Screen text is off. Enable it independently in Settings to capture visible text."},12.,MUTED)).child(row().items_start().gap(px(30.)).child(activities).child(moments)).into_any_element()
    }

    pub fn ask_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut conversation = column()
            .id("ask-conversation")
            .flex_1()
            .overflow_y_scroll()
            .gap(px(26.))
            .max_w(px(900.))
            .w_full()
            .mx_auto()
            .pt(px(20.));
        if let Some(c) = &self.answer {
            conversation = conversation
                .child(
                    row().justify_end().child(
                        panel()
                            .bg(rgb(0x25312e))
                            .px(px(21.))
                            .py(px(16.))
                            .max_w(px(650.))
                            .child(label(c.question.clone(), 14., TEXT)),
                    ),
                )
                .child(
                    row()
                        .items_start()
                        .gap(px(15.))
                        .child(icon(IconName::Sparkles, ACCENT))
                        .child(
                            column()
                                .flex_1()
                                .gap(px(17.))
                                .child(heading("LokalBot", 13.))
                                .child(
                                    label(c.answer.text.clone(), 14., TEXT).line_height(px(25.)),
                                ),
                        ),
                );
            let mut sources = row().gap(px(12.));
            for source in &c.answer.sources {
                if let Ok(e) = self.library.evidence(source) {
                    let target = e.meeting_id.clone();
                    let start = e.start;
                    sources = sources.child(
                        panel()
                            .id(format!("citation-{}", e.id))
                            .flex_1()
                            .p(px(14.))
                            .gap(px(8.))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, window, cx| {
                                if let Some(id) = &target {
                                    this.select(id.clone(), 1, window, cx);
                                    this.seek = start;
                                } else {
                                    this.navigate(Page::Timeline, window, cx);
                                }
                            }))
                            .child(heading(e.title, 12.))
                            .child(label(
                                format!("{} · {} ↗", e.kind, timecode(e.start)),
                                10.,
                                ACCENT,
                            )),
                    );
                }
            }
            conversation = conversation.child(sources);
        } else {
            conversation=conversation.child(empty("Ask about your library","Find decisions, owners, deadlines, or a conversation you want to revisit. Answers cite retained evidence; no matching evidence means no model request."));
        }
        column().flex_1().h_full().px(px(40.)).py(px(27.)).gap(px(24.)).child(row().child(page_header("Ask your memory","Answers with the conversation behind them.")).child(div().flex_1()).child(badge(&self.inference_label(),false))).child(conversation)
            .child(column().max_w(px(900.)).w_full().mx_auto().gap(px(12.)).child(row().gap(px(10.)).children(["Who owns the next actions?","What was decided about Linux?"].into_iter().enumerate().map(|(i,q)|button(("suggestion",i),q,IconName::Search,false).on_click(cx.listener(move|this,_,window,cx|{this.ask_input.update(cx,|s,cx|s.set_value(q,window,cx));this.submit_question(cx);})).into_any_element())))
            .child(row().p(px(10.)).rounded(px(11.)).bg(rgb(SURFACE)).border_1().border_color(rgb(BORDER)).child(Input::new(&self.ask_input).aria_label("Ask memory").flex_1()).child(button("send-question","Ask",IconName::ArrowUp,true).on_click(cx.listener(|this,_,_,cx|this.submit_question(cx)))))
            .child(label("Only retrieved evidence is sent to the approved inference destination. Saved conversations have their own lifetime.",10.,MUTED))).into_any_element()
    }

    pub fn type_page(&self, cx: &mut Context<Self>) -> AnyElement {
        scroll("type-scroll").child(page_header("Type","Speak a thought, or get help finishing it.")).child(panel().max_w(px(950.)).w_full().p(px(25.)).gap(px(20.)).child(section_header("Writing",IconName::Keyboard,"" )).child(Textarea::new(&self.writing).h(px(240.)).aria_label("Writing draft"))
            .child(row().child(button("dictate",if self.dictating{"Stop dictation"}else{"Dictate"},IconName::Mic,true).on_click(cx.listener(|this,_,_,cx|this.record(true,cx)))).child(button("complete-writing","Continue writing",IconName::Sparkles,false).on_click(cx.listener(|this,_,_,cx|{let text=this.writing.read(cx).value().to_string();if !text.trim().is_empty(){this.spawn("Writing",move|lib|{let grant=privacy::EgressGrant::acquire(lib)?;let(t,g)=inference::Engine::new(lib.settings()?)?.generate("writing","Continue the user's draft naturally. Return only the continuation, no commentary. Do not invent facts.",&text,None)?;grant.verify(lib)?;lib.save_generation(&g)?;Ok(Output::Text(format!("{text}{t}")))},cx);}}))).child(button("copy-writing","Copy",IconName::Copy,false).on_click(cx.listener(|this,_,_,cx|{cx.write_to_clipboard(ClipboardItem::new_string(this.writing.read(cx).value().to_string()));this.notice="Writing copied".into();cx.notify();}))))
            .child(label("Dictation uses your configured transcription backend. Scratch audio is removed after a successful transcription. Copy inserts text through an explicit clipboard action.",11.,MUTED).line_height(px(21.)))).into_any_element()
    }

    pub fn agent_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body=scroll("agent-scroll").child(page_header("Agent","Bring context to work in a folder you choose.")).child(panel().p(px(24.)).gap(px(18.)).child(heading("A report, then your approval",16.)).child(label("The agent can propose one direct command. Review its complete program and arguments before approving execution. It runs with your user permissions.",13.,MUTED).line_height(px(22.))).child(Input::new(&self.agent_input).aria_label("Agent task")).child(button("plan-task","Plan task",IconName::Bot,true).on_click(cx.listener(|this,_,_,cx|{let prompt=this.agent_input.read(cx).value().to_string();this.spawn("Agent plan",move|lib|Ok(Output::Agent(agent::plan(lib,&prompt)?)),cx);})))
            .child(label(format!("Workspace: {} · Agent Mode {}",if self.settings.agent_workspace.is_empty(){"choose one in Settings"}else{&self.settings.agent_workspace},if self.settings.agent_enabled{"enabled"}else{"off"}),11.,MUTED)));
        if let Some(task) = &self.agent_task {
            let mut card = panel()
                .p(px(24.))
                .gap(px(18.))
                .child(label(task.prompt.clone(), 13., ACCENT))
                .child(label(task.report.clone(), 14., TEXT).line_height(px(24.)))
                .child(badge(&task.status, false));
            if let Some(p) = &task.proposal {
                let task = task.clone();
                card = card
                    .child(
                        label(
                            format!(
                                "Program: {}\nArguments: {}\nReason: {}",
                                p.program,
                                serde_json::to_string(&p.args).unwrap_or_default(),
                                p.reason
                            ),
                            12.,
                            MUTED,
                        )
                        .line_height(px(22.)),
                    )
                    .child(
                        button(
                            "approve-command",
                            "Approve and run this command",
                            IconName::Play,
                            false,
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            let mut task = task.clone();
                            this.spawn(
                                "Approved command",
                                move |lib| {
                                    agent::approve_and_run(lib, &mut task)?;
                                    Ok(Output::Agent(task))
                                },
                                cx,
                            );
                        })),
                    );
            }
            body = body.child(card);
        }
        body.into_any_element()
    }

    pub fn settings_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = scroll("settings-scroll").child(page_header(
            "Settings",
            "Local storage, explicit permissions, and your chosen models.",
        ));
        body=body.child(panel().p(px(24.)).gap(px(16.)).child(section_header("Inference",IconName::Cpu,"" )).child(row().child(button("choose-local","Compatible server",IconName::Cpu,false).on_click(cx.listener(|this,_,window,cx|{this.backend_choice=Backend::Local;this.endpoint.update(cx,|s,cx|s.set_value("http://127.0.0.1:17872/v1",window,cx));this.model.update(cx,|s,cx|s.set_value("local",window,cx));cx.notify();}))).child(button("choose-openrouter","OpenRouter",IconName::Sparkles,false).on_click(cx.listener(|this,_,window,cx|{this.backend_choice=Backend::OpenRouter;this.endpoint.update(cx,|s,cx|s.set_value("https://openrouter.ai/api/v1",window,cx));this.model.update(cx,|s,cx|s.set_value("z-ai/glm-5.3-flash",window,cx));cx.notify();}))))
            .child(label("Endpoint",11.,MUTED)).child(Input::new(&self.endpoint).aria_label("Inference endpoint")).child(label("Model",11.,MUTED)).child(Input::new(&self.model).aria_label("Inference model")).child(Input::new(&self.key_input).aria_label("OpenRouter API key"))
            .child(label("Remote models receive retrieved meeting context and enabled screen text only after you approve this exact origin. OpenRouter uses private-only routing by default. Environment keys are never saved to the database.",12.,MUTED).line_height(px(21.)))
            .child(row().child(button("save-settings","Save settings",IconName::Check,true).on_click(cx.listener(|this,_,window,cx|this.save_config(false,window,cx)))).child(button("approve-origin","Approve inference origin",IconName::ShieldCheck,false).on_click(cx.listener(|this,_,window,cx|this.save_config(true,window,cx)))).child(button("revoke-origin","Revoke approvals",IconName::X,false).on_click(cx.listener(|this,_,_,cx|this.toggle_setting(|s|s.approved_origins.clear(),cx)))))
            .child(label(format!("Approved origins: {}",if self.settings.approved_origins.is_empty(){"none".into()}else{self.settings.approved_origins.join(", ")}),10.,MUTED)));
        body=body.child(panel().p(px(24.)).gap(px(16.)).child(section_header("Transcription",IconName::Mic,"CPU or explicitly approved API" )).child(label("Whisper executable",11.,MUTED)).child(Input::new(&self.whisper_exe)).child(label("Whisper GGML model path",11.,MUTED)).child(Input::new(&self.whisper_model))
            .child(preference("remote-audio","Remote audio transcription","Separate opt-in: sends audio to OpenRouter rather than local Whisper.",self.settings.remote_audio).on_click(cx.listener(|this,_,_,cx|this.toggle_setting(|s|s.remote_audio= !s.remote_audio,cx))))
            .child(preference("account-policy","Use account data policy","OpenRouter transcription currently cannot enforce private-only routing. Enabling this changes provider routing for text and audio.",self.settings.account_data_policy).on_click(cx.listener(|this,_,_,cx|this.toggle_setting(|s|s.account_data_policy= !s.account_data_policy,cx)))));
        body = body.child(
            panel()
                .p(px(24.))
                .gap(px(8.))
                .child(section_header(
                    "Privacy and capture",
                    IconName::ShieldCheck,
                    "",
                ))
                .child(
                    preference(
                        "activity-enabled",
                        "Track app and window activity",
                        "Activity only; no document text or pixels.",
                        self.settings.activity_enabled,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.activity_enabled = !s.activity_enabled, cx)
                    })),
                )
                .child(
                    preference(
                        "screen-text",
                        "Capture visible screen text",
                        "Off by default. Focus, secure fields, and exclusions must be verified.",
                        self.settings.screen_text_enabled,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.screen_text_enabled = !s.screen_text_enabled, cx)
                    })),
                )
                .child(
                    preference(
                        "screen-pixels",
                        "Keep encrypted screen pixels",
                        "Separate opt-in. Sensitive text drops the associated pixels.",
                        self.settings.pixels_enabled,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.pixels_enabled = !s.pixels_enabled, cx)
                    })),
                )
                .child(
                    preference(
                        "pause-capture",
                        "Pause capture",
                        "Cancels eligibility for pending screen captures.",
                        self.settings.paused,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.paused = !s.paused, cx)
                    })),
                )
                .child(
                    preference(
                        "meeting-access",
                        "External meeting-library access",
                        "Read-only CLI and MCP access. Off by default.",
                        self.settings.meeting_access,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.meeting_access = !s.meeting_access, cx)
                    })),
                )
                .child(
                    preference(
                        "screen-access",
                        "External screen-memory access",
                        "Independent grant; last seven days by default, no pixels or pixel paths.",
                        self.settings.screen_access,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.toggle_setting(|s| s.screen_access = !s.screen_access, cx)
                    })),
                )
                .child(
                    label(
                        format!(
                            "Retention: {} days · excluded apps: {}",
                            self.settings.retention_days,
                            self.settings.excluded_apps.join(", ")
                        ),
                        11.,
                        MUTED,
                    )
                    .mt(px(12.)),
                ),
        );
        body = body.child(
            panel()
                .p(px(24.))
                .gap(px(14.))
                .child(section_header(
                    "Retention and exclusions",
                    IconName::ShieldCheck,
                    "",
                ))
                .child(label(
                    "Keep unsaved screen text/pixels for this many days",
                    12.,
                    MUTED,
                ))
                .child(Input::new(&self.retention).aria_label("Retention days"))
                .child(label("Excluded apps (comma separated)", 12., MUTED))
                .child(Input::new(&self.exclusions).aria_label("Excluded apps"))
                .child(label(
                    "Excluded domains (comma separated; unknown browser domains refuse capture)",
                    12.,
                    MUTED,
                ))
                .child(Input::new(&self.domains).aria_label("Excluded domains"))
                .child(label(
                    "External screen access: last N days (blank permits all retained text)",
                    12.,
                    MUTED,
                ))
                .child(Input::new(&self.screen_days).aria_label("Screen access time scope"))
                .child(
                    label(
                        format!("Desktop helper: {}", self.capture_status),
                        11.,
                        MUTED,
                    )
                    .line_height(px(21.)),
                )
                .child(
                    button(
                        "save-capture-controls",
                        "Save capture settings",
                        IconName::Check,
                        true,
                    )
                    .on_click(
                        cx.listener(|this, _, window, cx| this.save_config(false, window, cx)),
                    ),
                ),
        );
        body = body
            .child(
                panel()
                    .p(px(24.))
                    .gap(px(16.))
                    .child(section_header("Agent Mode", IconName::Bot, ""))
                    .child(Input::new(&self.workspace).aria_label("Agent workspace"))
                    .child(
                        preference(
                            "agent-enabled",
                            "Enable Agent Mode",
                            "Every proposed executable still requires an explicit approval.",
                            self.settings.agent_enabled,
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.toggle_setting(|s| s.agent_enabled = !s.agent_enabled, cx)
                        })),
                    )
                    .child(
                        button(
                            "clear-agent",
                            "Clear saved agent history",
                            IconName::Trash,
                            false,
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            let result = this.library.clear_agent_history();
                            this.agent_task = None;
                            this.show_result(result, "Agent history cleared", cx);
                        })),
                    ),
            )
            .child(
                panel()
                    .p(px(24.))
                    .gap(px(12.))
                    .child(heading("Your local library", 15.))
                    .child(label(
                        self.library.root.to_string_lossy().into_owned(),
                        12.,
                        MUTED,
                    ))
                    .child(
                        button(
                            "clear-ask",
                            "Clear saved Ask conversations",
                            IconName::Trash,
                            false,
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            let result = this.library.clear_conversations();
                            this.answer = None;
                            this.show_result(result, "Ask history cleared", cx);
                        })),
                    ),
            )
            .child(
                button(
                    "save-bottom",
                    "Save model paths and workspace",
                    IconName::Check,
                    true,
                )
                .on_click(cx.listener(|this, _, window, cx| this.save_config(false, window, cx))),
            );
        body.into_any_element()
    }

    pub fn people(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut people: BTreeMap<String, Vec<&Meeting>> = BTreeMap::new();
        for m in &self.meetings {
            for name in &m.people {
                people.entry(name.clone()).or_default().push(m);
            }
        }
        scroll("people-scroll")
            .child(page_header(
                "People",
                "Names explicitly present in your meeting library.",
            ))
            .children(people.into_iter().map(|(name, meetings)| {
                panel()
                    .id(format!("person-{name}"))
                    .p(px(22.))
                    .gap(px(14.))
                    .child(
                        row()
                            .child(avatar(
                                &name.chars().take(2).collect::<String>(),
                                0x3e5673,
                                35.,
                            ))
                            .child(heading(name, 17.))
                            .child(div().flex_1())
                            .child(label(format!("{} meetings", meetings.len()), 11., MUTED)),
                    )
                    .children(meetings.into_iter().map(|m| {
                        let id = m.id.clone();
                        button(
                            format!("person-meeting-{id}"),
                            &m.title,
                            IconName::Video,
                            false,
                        )
                        .on_click(cx.listener(move |this, _, window, cx| {
                            this.select(id.clone(), 0, window, cx)
                        }))
                        .into_any_element()
                    }))
                    .into_any_element()
            }))
            .into_any_element()
    }
    pub fn projects(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut topics: BTreeMap<String, Vec<&Meeting>> = BTreeMap::new();
        for m in &self.meetings {
            let mut seen = std::collections::HashSet::new();
            for word in m
                .title
                .split_whitespace()
                .filter(|w| w.len() > 3 && w.chars().next().is_some_and(char::is_uppercase))
            {
                if seen.insert(word) {
                    topics.entry(word.into()).or_default().push(m);
                }
            }
        }
        scroll("projects-scroll").child(page_header("Projects","Topics named in your meetings; derived from retained evidence." )).child(label("This view groups observed meeting titles. It does not infer that planned work has been completed.",12.,MUTED)).children(topics.into_iter().map(|(topic,meetings)|panel().id(format!("project-{topic}")).p(px(22.)).gap(px(14.)).child(row().child(icon(IconName::Folder,ACCENT)).child(heading(topic,17.))).children(meetings.into_iter().map(|m|{let id=m.id.clone();button(format!("project-meeting-{id}"),&m.title,IconName::Video,false).on_click(cx.listener(move|this,_,window,cx|this.select(id.clone(),0,window,cx))).into_any_element()})).into_any_element())).into_any_element()
    }
}
