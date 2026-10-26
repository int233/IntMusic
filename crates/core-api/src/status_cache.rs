use super::*;

pub(crate) async fn refresh_library_counts(state: &AppState) -> Result<()> {
    let started = tokio::time::Instant::now();
    let counts = core_db::library_counts(state.pool()).await?;
    if let Ok(mut cached) = state.inner.library_counts.write() {
        *cached = counts;
    }
    if started.elapsed() > Duration::from_secs(2) {
        warn!(
            elapsed_ms = started.elapsed().as_millis(),
            "library statistics refresh was slow"
        );
    }
    Ok(())
}

/// One background statistics query serves every client and startup probe.
pub(crate) fn start_library_counts_monitor(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        let mut revision = state.inner.library_revision.load(Ordering::SeqCst);
        let mut refreshed_at = tokio::time::Instant::now();
        loop {
            interval.tick().await;
            let current = state.inner.library_revision.load(Ordering::SeqCst);
            if current == revision && refreshed_at.elapsed() < Duration::from_secs(60) {
                continue;
            }
            match refresh_library_counts(&state).await {
                Ok(()) => {
                    revision = current;
                    refreshed_at = tokio::time::Instant::now();
                }
                Err(error) => warn!(%error, "could not refresh library statistics"),
            }
        }
    });
}
