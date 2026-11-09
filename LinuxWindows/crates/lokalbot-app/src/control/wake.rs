//! The local-model wake behind `ask_library` and `lokalbot-cli ask`
//! (`AgentAccessManager.swift`): the CLI leaves a file in `control/`, and while
//! meeting access is on the app starts its Think server and keeps it warm for
//! follow-ups, returning the memory ten minutes after the last question.

use std::sync::Arc;
use std::time::{Duration, Instant};

use gpui_kit::{AppContext as _, Context};
use lokalbot_ai::runtime::Lease;
use lokalbot_core::access;
use lokalbot_core::settings::SummarizerBackend;
use parking_lot::Mutex;

use super::ControlHost;

const LEASE_TTL: Duration = Duration::from_secs(600);

#[derive(Default)]
pub struct WakeState {
    lease: Arc<Mutex<Option<(Lease, Instant)>>>,
    busy: bool,
}

impl ControlHost {
    pub(super) fn tick_wake(&mut self, cx: &mut Context<Self>) {
        let expired = self
            .wake
            .lease
            .lock()
            .as_ref()
            .is_some_and(|(_, since)| since.elapsed() >= LEASE_TTL);
        if expired || !access::meetings_access_enabled(&self.paths) {
            self.wake.lease.lock().take();
        }
        if self.wake.busy
            || !access::meetings_access_enabled(&self.paths)
            || !access::consume_wake(&self.paths)
        {
            return;
        }
        let settings = self.data.read(cx).settings.clone();
        let paths = self.paths.clone();
        // The failure strings are the messages the CLI relays to agents.
        let resolved = match settings.summarizer_backend {
            SummarizerBackend::BuiltIn => lokalbot_ai::catalog::entry(&settings.built_in_model_id)
                .filter(|entry| lokalbot_ai::catalog::is_downloaded(&paths, entry))
                .ok_or("The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again."),
            SummarizerBackend::ChatGptPlan | SummarizerBackend::ClaudePlan => Err("The Think model is set to your plan; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models."),
            SummarizerBackend::Ollama | SummarizerBackend::OpenAICompatible => Err("The Think model is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models."),
        };
        let entry = match resolved {
            Ok(entry) => entry,
            Err(reason) => {
                let _ = access::write_wake_error(&paths, reason);
                return;
            }
        };
        let Some(engine) = cx
            .try_global::<crate::bridge::EngineHandle>()
            .map(|e| e.0.clone())
        else {
            let _ = access::write_wake_error(&paths, "LokalBot's engine isn't running.");
            return;
        };
        self.wake.busy = true;
        let slot = self.wake.lease.clone();
        cx.spawn(async move |this, cx| {
            let started = cx
                .background_spawn(async move { engine.runtime().main_server(entry) })
                .await;
            let _ = this.update(cx, |host, _| {
                host.wake.busy = false;
                match started {
                    Ok(lease) => {
                        // Replaced, not stacked; a crashed server is revived by
                        // leasing again instead of being trusted.
                        *slot.lock() = Some((lease, Instant::now()));
                        access::clear_wake_error(&host.paths);
                    }
                    Err(err) => {
                        let _ = access::write_wake_error(
                            &host.paths,
                            &format!("LokalBot's model server failed to start: {err:#}"),
                        );
                    }
                }
            });
        })
        .detach();
    }
}
