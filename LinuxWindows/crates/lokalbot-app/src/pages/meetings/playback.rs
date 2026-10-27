//! Meeting playback through `lokalbot_audio::Player`: play/pause, seeking,
//! speed, and a 10 Hz position poll while playing that drives the waveform
//! playhead and the transcript highlight.

use std::sync::Arc;
use std::time::Duration;

use gpui_kit::{AppContext as _, Context};
use lokalbot_audio::Player;

use super::MeetingsPage;

impl MeetingsPage {
    /// Opens the selected meeting's tracks off the UI thread.
    pub(super) fn open_player(&mut self, cx: &mut Context<Self>) {
        self.stop_playback();
        let Some(doc) = self.doc.clone() else { return };
        if !doc.has_audio || doc.meeting.is_live() {
            return;
        }
        let (mic, system, id) = (doc.mic.clone(), doc.system.clone(), doc.meeting.id);
        self.player_loading = true;
        cx.spawn(async move |this, cx| {
            let opened = cx
                .background_spawn(async move { Player::open(mic.as_deref(), system.as_deref()) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.doc.as_ref().map(|d| d.meeting.id) != Some(id) {
                    return;
                }
                this.player_loading = false;
                match opened {
                    Ok(player) => {
                        player.set_speed(this.speed);
                        this.player = Some(Arc::new(player));
                    }
                    Err(err) => log::warn!("could not open audio for {id}: {err:#}"),
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// Pauses and forgets the current player (switching meetings).
    pub(super) fn stop_playback(&mut self) {
        if let Some(player) = self.player.take() {
            player.pause();
        }
        self.poll = None;
        self.playing = false;
        self.playhead = 0.;
        self.player_loading = false;
    }

    /// Pauses without forgetting the position (leaving the page).
    pub(super) fn pause_playback(&mut self) {
        if let Some(player) = self.player.as_ref() {
            player.pause();
        }
        self.playing = false;
        self.poll = None;
    }

    pub(super) fn toggle_playback(&mut self, cx: &mut Context<Self>) {
        let Some(player) = self.player.clone() else {
            return;
        };
        if player.is_playing() {
            self.pause_playback();
        } else {
            self.start(player.play(), cx);
        }
        cx.notify();
    }

    /// Plays from `seconds` (transcript timestamps).
    pub(super) fn play_from(&mut self, seconds: f64, cx: &mut Context<Self>) {
        let Some(player) = self.player.clone() else {
            return;
        };
        player.seek(seconds);
        self.sync_player(cx);
        if !player.is_playing() {
            self.start(player.play(), cx);
        }
    }

    /// Plays a short excerpt (speaker review "Listen").
    pub(super) fn play_excerpt(&mut self, start: f64, end: f64, cx: &mut Context<Self>) {
        let Some(player) = self.player.clone() else {
            return;
        };
        self.start(player.play_range(start, end), cx);
    }

    /// Moves the playhead to `fraction` of the recording.
    pub(super) fn seek(&mut self, fraction: f32, cx: &mut Context<Self>) {
        let fraction = fraction.clamp(0., 1.);
        match self.player.clone() {
            Some(player) => {
                player.seek(f64::from(fraction) * player.duration());
                self.sync_player(cx);
            }
            None => self.playhead = fraction,
        }
        cx.notify();
    }

    /// Moves by `seconds` (Left/Right arrows).
    pub(super) fn seek_by(&mut self, seconds: f64, cx: &mut Context<Self>) {
        let Some(player) = self.player.clone() else {
            return;
        };
        player.seek((player.position() + seconds).clamp(0., player.duration()));
        self.sync_player(cx);
        cx.notify();
    }

    pub(super) fn set_speed(&mut self, speed: f32, cx: &mut Context<Self>) {
        self.speed = speed;
        if let Some(player) = self.player.as_ref() {
            player.set_speed(speed);
        }
        cx.notify();
    }

    /// Seconds played and the recording's length, for the time label.
    pub(super) fn playback_times(&self, fallback_duration: f64) -> (f64, f64) {
        match self.player.as_ref() {
            Some(player) => (player.position(), player.duration()),
            None => (
                f64::from(self.playhead) * fallback_duration,
                fallback_duration,
            ),
        }
    }

    fn start(&mut self, result: anyhow::Result<()>, cx: &mut Context<Self>) {
        if let Err(err) = result {
            let message = format!("{err:#}");
            self.data
                .update(cx, |data, cx| data.show_error(message, cx));
            return;
        }
        self.playing = true;
        self.poll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                let playing = this
                    .update(cx, |this, cx| this.sync_player(cx))
                    .unwrap_or(false);
                if !playing {
                    break;
                }
            }
        }));
        cx.notify();
    }

    /// Mirrors the player's position; returns whether it is still playing.
    fn sync_player(&mut self, cx: &mut Context<Self>) -> bool {
        let Some(player) = self.player.clone() else {
            return false;
        };
        let position = player.position();
        let duration = player.duration().max(0.001);
        self.playhead = (position / duration).clamp(0., 1.) as f32;
        self.playing = player.is_playing();
        if self.playing {
            // The playing segment is highlighted like cited evidence.
            self.focus_at = Some(position);
        } else {
            self.poll = None;
        }
        cx.notify();
        self.playing
    }
}
