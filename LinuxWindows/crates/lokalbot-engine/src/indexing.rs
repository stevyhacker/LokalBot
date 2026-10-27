//! Brings search up to date at startup, for meetings this app did not just
//! process: the keyword index first, then meaning-search vectors for meetings
//! without current ones (`SemanticIndexer` on macOS).

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use crate::models::Models;
use crate::{BackgroundItem, BackgroundKind, EngineEvent, Shared};

const BACKGROUND_ID: &str = "reindex";

pub fn start(shared: Arc<Shared>, models: Models) {
    let spawned = std::thread::Builder::new()
        .name("lokalbot-index".into())
        .spawn(move || {
            // Let the window and the first engine events settle.
            std::thread::sleep(Duration::from_secs(5));
            match shared.library.reindex_stale() {
                Ok(0) => {}
                Ok(count) => {
                    log::info!("indexed {count} meetings for search");
                    shared.emit(EngineEvent::LibraryChanged);
                }
                Err(err) => log::warn!("updating the search index failed: {err:#}"),
            }
            if !shared.settings().semantic_search_enabled
                || !models.missing(&models.embedding_requirements()).is_empty()
            {
                return;
            }
            // Embedding is heavy; wait until nothing is capturing audio.
            while shared.capture_active.load(Ordering::Relaxed) {
                if shared.is_shutting_down() {
                    return;
                }
                std::thread::sleep(Duration::from_secs(10));
            }
            let result = lokalbot_ai::embeddings::index_pending(
                &shared.runtime,
                &shared.library,
                &shared.shutting_down,
                &mut |done, total| {
                    shared.set_background(BackgroundItem {
                        id: BACKGROUND_ID.into(),
                        kind: BackgroundKind::Reindex,
                        title: "Updating meaning search".into(),
                        detail: format!("{done} of {total} meetings"),
                        progress: Some(done as f32 / total.max(1) as f32),
                    });
                },
            );
            shared.clear_background(BACKGROUND_ID);
            match result {
                Ok(0) => {}
                Ok(count) => log::info!("embedded {count} meetings for meaning search"),
                Err(err) if shared.is_shutting_down() => log::debug!("indexing stopped: {err:#}"),
                Err(err) => log::warn!("updating meaning search failed: {err:#}"),
            }
        });
    if let Err(err) = spawned {
        log::warn!("could not start search indexing: {err}");
    }
}
