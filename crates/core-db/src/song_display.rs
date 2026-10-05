use super::*;

/// Persist a choice on every known copy of this album edition. A newly scanned
/// copy inherits the latest edition choice through track_display_modes.
pub async fn set_track_display_mode(pool: &DbPool, track_id: i64, mode: &str) -> Result<()> {
    if !matches!(mode, "inherit" | "merged" | "independent") {
        bail!("invalid song display mode");
    }
    let mut tx = pool.begin().await?;
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?1)")
        .bind(track_id)
        .fetch_one(&mut *tx)
        .await?;
    if !exists {
        bail!("track not found");
    }
    sqlx::query(r#"
        INSERT INTO track_display_preferences (track_id, mode, updated_at)
        SELECT t.id, ?2, ?3 FROM tracks t
        LEFT JOIN track_catalog_links member ON member.track_id = t.id
        WHERE t.id = ?1 OR COALESCE(member.release_identity_id, member.release_track_id) =
          (SELECT COALESCE(release_identity_id, release_track_id) FROM track_catalog_links WHERE track_id = ?1)
        ON CONFLICT(track_id) DO UPDATE SET mode = excluded.mode, updated_at = excluded.updated_at
    "#).bind(track_id).bind(mode).bind(Utc::now().to_rfc3339()).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(())
}
