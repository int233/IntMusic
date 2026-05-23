use anyhow::Result;
use async_trait::async_trait;
use protocol::TrackSummary;
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrackSearchDoc {
    pub track_id: i64,
    pub title: String,
    pub album: Option<String>,
    pub artists: Vec<String>,
    pub genres: Vec<String>,
    pub lyrics: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub entity_type: String,
    pub entity_id: i64,
    pub score: f32,
    pub title: String,
}

#[async_trait]
pub trait SearchIndex: Send + Sync {
    async fn rebuild(&self) -> Result<()>;
    async fn upsert_track(&self, track: &TrackSearchDoc) -> Result<()>;
    async fn delete_track(&self, track_id: i64) -> Result<()>;
    async fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>>;
}

#[derive(Clone)]
pub struct SqliteSearchIndex {
    pool: SqlitePool,
}

impl SqliteSearchIndex {
    pub fn new(pool: SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn search_tracks(&self, query: &str, limit: u32) -> Result<Vec<TrackSummary>> {
        core_db::search_tracks(&self.pool, query, limit).await
    }
}

#[async_trait]
impl SearchIndex for SqliteSearchIndex {
    async fn rebuild(&self) -> Result<()> {
        sqlx::query("DELETE FROM search_fts")
            .execute(&self.pool)
            .await?;
        sqlx::query(
            r#"
            INSERT INTO search_fts (track_id, title, album, artist, genre, lyrics)
            SELECT
                t.id,
                t.title,
                COALESCE(al.title, ''),
                COALESCE(GROUP_CONCAT(DISTINCT ar.name), ''),
                COALESCE(GROUP_CONCAT(DISTINCT g.name), ''),
                COALESCE(l.text, '')
            FROM tracks t
            LEFT JOIN albums al ON al.id = t.album_id
            LEFT JOIN track_artists ta ON ta.track_id = t.id
            LEFT JOIN artists ar ON ar.id = ta.artist_id
            LEFT JOIN track_genres tg ON tg.track_id = t.id
            LEFT JOIN genres g ON g.id = tg.genre_id
            LEFT JOIN lyrics l ON l.track_id = t.id
            GROUP BY t.id
            "#,
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn upsert_track(&self, track: &TrackSearchDoc) -> Result<()> {
        self.delete_track(track.track_id).await?;
        sqlx::query(
            "INSERT INTO search_fts (track_id, title, album, artist, genre, lyrics) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        )
        .bind(track.track_id)
        .bind(&track.title)
        .bind(track.album.as_deref().unwrap_or_default())
        .bind(track.artists.join("; "))
        .bind(track.genres.join("; "))
        .bind(track.lyrics.as_deref().unwrap_or_default())
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    async fn delete_track(&self, track_id: i64) -> Result<()> {
        sqlx::query("DELETE FROM search_fts WHERE track_id = ?1")
            .bind(track_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>> {
        let pattern = format!("%{}%", query);
        let rows = sqlx::query(
            r#"
            SELECT track_id, title
            FROM search_fts
            WHERE title LIKE ?1 OR album LIKE ?1 OR artist LIKE ?1 OR genre LIKE ?1 OR lyrics LIKE ?1
            LIMIT ?2
            "#,
        )
        .bind(pattern)
        .bind(limit as i64)
        .fetch_all(&self.pool)
        .await?;

        rows.into_iter()
            .map(|row| {
                use sqlx::Row;
                Ok(SearchResult {
                    entity_type: "track".to_string(),
                    entity_id: row.try_get("track_id")?,
                    score: 1.0,
                    title: row.try_get("title")?,
                })
            })
            .collect()
    }
}

pub fn cjk_ngrams(input: &str, n: usize) -> Vec<String> {
    let chars: Vec<char> = input.chars().filter(|ch| !ch.is_whitespace()).collect();
    if chars.len() < n || n == 0 {
        return Vec::new();
    }
    chars
        .windows(n)
        .map(|window| window.iter().collect())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::cjk_ngrams;

    #[test]
    fn builds_two_char_cjk_grams() {
        assert_eq!(cjk_ngrams("周杰伦", 2), vec!["周杰", "杰伦"]);
    }
}
