use std::{
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    time::SystemTime,
};

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use core_db::{DbPool, FileIngest, TrackIngest};
use lofty::{
    config::WriteOptions,
    file::{AudioFile, TaggedFile, TaggedFileExt},
    prelude::{Accessor, ItemKey},
    probe::Probe,
    tag::{ItemValue, Tag},
};
use protocol::ScanProgressPayload;
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;
use tracing::{debug, warn};
use walkdir::WalkDir;

#[derive(Debug, Clone)]
pub struct ScannerConfig {
    pub extensions: Vec<String>,
    pub artist_separators: Vec<String>,
    pub genre_separators: Vec<String>,
}

impl Default for ScannerConfig {
    fn default() -> Self {
        Self {
            extensions: vec!["mp3".to_string(), "flac".to_string()],
            artist_separators: vec![
                ",".to_string(),
                ";".to_string(),
                "\u{ff1b}".to_string(),
                "\u{3001}".to_string(),
            ],
            genre_separators: vec![
                ",".to_string(),
                ";".to_string(),
                "\u{ff1b}".to_string(),
                "\u{3001}".to_string(),
            ],
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ScanSummary {
    pub scanned_files: u64,
    pub imported_tracks: u64,
    pub problem_files: u64,
}

impl From<&ScanSummary> for ScanProgressPayload {
    fn from(summary: &ScanSummary) -> Self {
        Self {
            scanned_files: summary.scanned_files,
            imported_tracks: summary.imported_tracks,
            problem_files: summary.problem_files,
        }
    }
}

#[derive(Debug, Clone)]
pub enum ScannerEvent {
    Started,
    Progress(ScanSummary),
    Finished(ScanSummary),
    Problem { path: String, message: String },
}

pub type ScannerEventSender = mpsc::UnboundedSender<ScannerEvent>;

pub async fn scan_all_roots(
    pool: DbPool,
    config: ScannerConfig,
    events: Option<ScannerEventSender>,
) -> Result<ScanSummary> {
    if let Some(events) = &events {
        let _ = events.send(ScannerEvent::Started);
    }

    let roots = core_db::enabled_library_roots(&pool).await?;
    let mut summary = ScanSummary::default();

    for root in roots {
        let root_path = PathBuf::from(&root.path);
        if !root_path.exists() {
            warn!(path = %root.path, "configured library root does not exist");
            continue;
        }

        for entry in WalkDir::new(&root_path)
            .follow_links(false)
            .into_iter()
            .filter_map(Result::ok)
        {
            if !entry.file_type().is_file() {
                continue;
            }
            let path = entry.path();
            if !is_supported_audio(path, &config.extensions) {
                continue;
            }

            summary.scanned_files += 1;
            match scan_one_file(&pool, root.id, &root_path, path, &config).await {
                Ok(true) => summary.imported_tracks += 1,
                Ok(false) => summary.problem_files += 1,
                Err(error) => {
                    summary.problem_files += 1;
                    let message = error.to_string();
                    warn!(path = %path.display(), error = %message, "failed to scan file");
                    if let Some(events) = &events {
                        let _ = events.send(ScannerEvent::Problem {
                            path: path.display().to_string(),
                            message,
                        });
                    }
                }
            }

            if summary.scanned_files % 25 == 0 {
                if let Some(events) = &events {
                    let _ = events.send(ScannerEvent::Progress(summary.clone()));
                }
            }
        }
    }

    if let Some(events) = &events {
        let _ = events.send(ScannerEvent::Finished(summary.clone()));
    }

    Ok(summary)
}

async fn scan_one_file(
    pool: &DbPool,
    library_root_id: i64,
    root_path: &Path,
    path: &Path,
    config: &ScannerConfig,
) -> Result<bool> {
    let metadata =
        std::fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;
    let relative_path = path
        .strip_prefix(root_path)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/");
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_lowercase();
    let modified_at = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let modified_at: DateTime<Utc> = modified_at.into();
    let quick_hash = quick_hash(path).ok();

    match read_track_metadata(path, config) {
        Ok(track) => {
            let file = FileIngest {
                library_root_id,
                path: core_db::normalize_path(path),
                relative_path,
                extension,
                size_bytes: metadata.len() as i64,
                modified_at: modified_at.to_rfc3339(),
                quick_hash,
                scan_status: "ok".to_string(),
                scan_message: None,
                codec: path
                    .extension()
                    .and_then(|value| value.to_str())
                    .map(|value| value.to_lowercase()),
                sample_rate: None,
                channels: None,
                duration_ms: track.duration_ms,
                bitrate: None,
                bit_depth: None,
            };
            core_db::upsert_scanned_file(pool, &file, Some(&track)).await?;
            debug!(path = %path.display(), "imported track");
            Ok(true)
        }
        Err(error) => {
            let file = FileIngest {
                library_root_id,
                path: core_db::normalize_path(path),
                relative_path,
                extension,
                size_bytes: metadata.len() as i64,
                modified_at: modified_at.to_rfc3339(),
                quick_hash,
                scan_status: "tag_parse_error".to_string(),
                scan_message: Some(error.to_string()),
                codec: None,
                sample_rate: None,
                channels: None,
                duration_ms: None,
                bitrate: None,
                bit_depth: None,
            };
            core_db::upsert_scanned_file(pool, &file, None).await?;
            Ok(false)
        }
    }
}

fn read_track_metadata(path: &Path, config: &ScannerConfig) -> Result<TrackIngest> {
    let tagged_file = Probe::open(path)
        .with_context(|| format!("failed to open {}", path.display()))?
        .read()
        .with_context(|| format!("failed to read tags from {}", path.display()))?;
    let properties = tagged_file.properties();
    let tag = tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag());

    let mut track = TrackIngest {
        duration_ms: Some(properties.duration().as_millis() as i64),
        ..Default::default()
    };

    if let Some(tag) = tag {
        track.title = tag
            .title()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_default();
        track.album = tag
            .album()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty());
        track.track_artists = collect_tag_values(
            tag,
            &[ItemKey::TrackArtists, ItemKey::TrackArtist],
            &config.artist_separators,
        );
        if track.track_artists.is_empty() {
            track.track_artists = tag
                .artist()
                .map(|value| split_multi_value(&value, &config.artist_separators))
                .unwrap_or_default();
        }
        track.album_artists =
            collect_tag_values(tag, &[ItemKey::AlbumArtist], &config.artist_separators);
        track.composers = collect_tag_values(tag, &[ItemKey::Composer], &config.artist_separators);
        track.lyricists = collect_tag_values(
            tag,
            &[ItemKey::Lyricist, ItemKey::OriginalLyricist],
            &config.artist_separators,
        );
        track.genres = tag
            .genre()
            .map(|value| split_multi_value(&value, &config.genre_separators))
            .unwrap_or_default();
        track.track_number = tag.track().map(|value| value as i64);
        track.track_total = tag.track_total().map(|value| value as i64);
        track.disc_number = tag.disk().map(|value| value as i64);
        track.disc_total = tag.disk_total().map(|value| value as i64);
        track.date = tag.year().map(|year| year.to_string());
        track.year = tag.year().map(|year| year as i64);
        track.comment = tag.get_string(&ItemKey::Comment).map(ToOwned::to_owned);
    }

    if let Some((kind, lyrics)) = find_lyrics(&tagged_file, path) {
        track.lyrics_kind = Some(kind);
        track.lyrics = Some(lyrics);
    }
    if let Some((rating, scale)) = find_rating(&tagged_file) {
        track.tag_rating = Some(rating);
        track.tag_rating_scale = Some(scale);
    }

    if track.title.trim().is_empty() {
        anyhow::bail!("missing required embedded TITLE tag");
    }
    if track.track_artists.is_empty() {
        anyhow::bail!("missing required embedded ARTIST tag");
    }

    Ok(track)
}

fn collect_tag_values(
    tag: &lofty::tag::Tag,
    keys: &[ItemKey],
    separators: &[String],
) -> Vec<String> {
    let mut values = Vec::new();
    for key in keys {
        for value in tag.get_strings(key) {
            values.extend(split_multi_value(value, separators));
        }
    }
    values.sort();
    values.dedup();
    values
}

pub fn write_rating_tag(path: &Path, rating: i64, scale: i64) -> Result<()> {
    let scale = normalize_rating_scale(scale);
    let rating = rating.clamp(0, scale);
    let mut tagged_file = Probe::open(path)
        .with_context(|| format!("failed to open {}", path.display()))?
        .read()
        .with_context(|| format!("failed to read tags from {}", path.display()))?;

    if tagged_file.primary_tag_mut().is_none() {
        tagged_file.insert_tag(Tag::new(tagged_file.primary_tag_type()));
    }
    let tag = tagged_file
        .primary_tag_mut()
        .with_context(|| format!("failed to create writable tag for {}", path.display()))?;

    tag.insert_text(ItemKey::Popularimeter, rating.to_string());
    tagged_file
        .save_to_path(path, WriteOptions::default())
        .with_context(|| format!("failed to write rating tag to {}", path.display()))?;
    Ok(())
}

fn find_rating(tagged_file: &TaggedFile) -> Option<(i64, i64)> {
    let mut candidates = Vec::new();
    for tag in tagged_file.tags() {
        for item in tag.items() {
            let key = item
                .key()
                .map_key(tag.tag_type(), true)
                .unwrap_or_default()
                .to_ascii_uppercase();
            let raw_key = format!("{:?}", item.key()).to_ascii_uppercase();
            let description = item.description().to_ascii_uppercase();
            let is_rating_key = item.key() == &ItemKey::Popularimeter
                || [key.as_str(), raw_key.as_str(), description.as_str()]
                    .iter()
                    .any(|value| is_rating_key_name(value));
            if !is_rating_key {
                continue;
            }

            if let Some(text) = item.value().text().or_else(|| item.value().locator()) {
                if let Some((rating, scale)) = parse_rating_text(text) {
                    candidates.push((rating, scale));
                }
            } else if let Some(binary) = item.value().binary() {
                if let Some((rating, scale)) = parse_popm_binary(binary) {
                    candidates.push((rating, scale));
                }
            }
        }
    }
    candidates.into_iter().max_by_key(|(rating, scale)| {
        if *scale > 0 {
            rating.saturating_mul(100) / scale
        } else {
            0
        }
    })
}

fn is_rating_key_name(value: &str) -> bool {
    let compact: String = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .flat_map(char::to_uppercase)
        .collect();
    compact == "RATING"
        || compact == "POPM"
        || compact == "RATE"
        || compact == "POPULARIMETER"
        || compact.contains("POPM")
        || compact.contains("POPULARIMETER")
        || compact.contains("RATING")
}

fn parse_rating_text(text: &str) -> Option<(i64, i64)> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if let Some((left, right)) = text.split_once('/') {
        let rating = parse_rating_number(left)?;
        let scale = parse_rating_number(right)?;
        if scale > 0 {
            return Some((rating.clamp(0, scale), normalize_rating_scale(scale)));
        }
    }

    let text = text.trim_end_matches('%').trim();
    if let Ok(float) = text.parse::<f64>() {
        if (0.0..=1.0).contains(&float) {
            return Some(((float * 100.0).round() as i64, 100));
        }
        if (0.0..=5.0).contains(&float) && text.contains('.') {
            return Some(((float * 20.0).round() as i64, 100));
        }
    }

    let rating = parse_rating_number(text)?;
    let scale = if rating <= 5 {
        5
    } else if rating <= 100 {
        100
    } else if rating <= 255 {
        return Some((((rating * 100) + 127) / 255, 100));
    } else {
        return None;
    };
    Some((rating.clamp(0, scale), scale))
}

fn parse_rating_number(text: &str) -> Option<i64> {
    text.trim()
        .parse::<f64>()
        .ok()
        .map(|value| value.round() as i64)
}

fn parse_popm_binary(binary: &[u8]) -> Option<(i64, i64)> {
    let rating_byte = binary
        .iter()
        .position(|byte| *byte == 0)
        .and_then(|index| binary.get(index + 1))
        .or_else(|| binary.first())?;
    Some((((*rating_byte as i64) * 100 + 127) / 255, 100))
}

fn normalize_rating_scale(scale: i64) -> i64 {
    if scale <= 5 {
        5
    } else {
        100
    }
}

pub fn extract_lyrics_from_path(path: &Path) -> Result<Option<(String, String)>> {
    let tagged_file = Probe::open(path)
        .with_context(|| format!("failed to open audio file {}", path.display()))?
        .read()
        .with_context(|| format!("failed to read audio tags {}", path.display()))?;
    Ok(find_lyrics(&tagged_file, path))
}

fn find_lyrics(tagged_file: &TaggedFile, path: &Path) -> Option<(String, String)> {
    let mut candidates = Vec::new();
    for tag in tagged_file.tags() {
        collect_lyrics_candidates(tag, &mut candidates);
    }

    if let Some(external_lrc) = read_sidecar_lrc(path) {
        candidates.push((90, "lrc".to_string(), external_lrc));
    }

    candidates.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.2.len().cmp(&left.2.len()))
    });
    candidates
        .into_iter()
        .find(|(_, _, text)| !text.trim().is_empty())
        .map(|(_, kind, text)| (kind, normalize_lyrics_text(&text)))
}

fn collect_lyrics_candidates(tag: &Tag, candidates: &mut Vec<(u8, String, String)>) {
    for item in tag.items() {
        let Some(text) = item.value().text().or_else(|| item.value().locator()) else {
            if let ItemValue::Binary(_) = item.value() {
                continue;
            }
            continue;
        };
        if text.trim().is_empty() {
            continue;
        }

        let mapped_key = item
            .key()
            .map_key(tag.tag_type(), true)
            .unwrap_or_default()
            .to_ascii_uppercase();
        let raw_key = match item.key() {
            ItemKey::Unknown(value) => value.to_ascii_uppercase(),
            key => format!("{key:?}").to_ascii_uppercase(),
        };
        let description = item.description().to_ascii_uppercase();
        let is_standard_lyrics = item.key() == &ItemKey::Lyrics;
        let looks_like_lyrics_key = [mapped_key.as_str(), raw_key.as_str(), description.as_str()]
            .iter()
            .any(|value| {
                value == &"LYRICS"
                    || value == &"UNSYNCEDLYRICS"
                    || value == &"SYNCEDLYRICS"
                    || value.contains("LYRICS")
                    || value.contains("LYRIC")
                    || value.contains("LRC")
            });
        if !is_standard_lyrics && !looks_like_lyrics_key && !looks_like_lrc(text) {
            continue;
        }

        let kind = if looks_like_lrc(text) { "lrc" } else { "text" };
        let mut score = if is_standard_lyrics { 80 } else { 60 };
        if kind == "lrc" {
            score += 10;
        }
        candidates.push((score, kind.to_string(), text.to_string()));
    }
}

fn read_sidecar_lrc(path: &Path) -> Option<String> {
    for lrc_path in [path.with_extension("lrc"), path.with_extension("LRC")] {
        if let Some(text) = std::fs::read_to_string(&lrc_path)
            .ok()
            .filter(|text| !text.trim().is_empty())
        {
            return Some(text);
        }
    }
    None
}

fn looks_like_lrc(text: &str) -> bool {
    text.lines().take(20).any(|line| {
        let line = line.trim_start();
        line.len() >= 7
            && line.starts_with('[')
            && line
                .chars()
                .nth(1)
                .map(|ch| ch.is_ascii_digit())
                .unwrap_or(false)
            && line.contains(':')
            && line.contains(']')
    })
}

fn normalize_lyrics_text(text: &str) -> String {
    text.replace("\r\n", "\n").replace('\r', "\n")
}

fn is_supported_audio(path: &Path, extensions: &[String]) -> bool {
    let Some(extension) = path.extension().and_then(|value| value.to_str()) else {
        return false;
    };
    extensions
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(extension))
}

fn split_multi_value(value: &str, separators: &[String]) -> Vec<String> {
    let mut values = vec![value.trim().to_string()];
    for separator in separators {
        values = values
            .into_iter()
            .flat_map(|part| {
                part.split(separator)
                    .map(str::trim)
                    .filter(|part| !part.is_empty())
                    .map(ToOwned::to_owned)
                    .collect::<Vec<_>>()
            })
            .collect();
    }
    values
}

fn quick_hash(path: &Path) -> Result<String> {
    const CHUNK_SIZE: usize = 64 * 1024;
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK_SIZE];

    let read = file.read(&mut buffer)?;
    hasher.update(&buffer[..read]);

    if len > CHUNK_SIZE as u64 {
        let offset = len.saturating_sub(CHUNK_SIZE as u64);
        file.seek(SeekFrom::Start(offset))?;
        let read = file.read(&mut buffer)?;
        hasher.update(&buffer[..read]);
    }

    hasher.update(len.to_le_bytes());
    Ok(hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::{is_rating_key_name, parse_rating_text, split_multi_value};

    #[test]
    fn splits_only_configured_separators() {
        let separators = vec![
            ";".to_string(),
            "\u{ff1b}".to_string(),
            "\u{3001}".to_string(),
        ];
        assert_eq!(
            split_multi_value("A/B; C\u{ff1b}D\u{3001}E", &separators),
            vec!["A/B", "C", "D", "E"]
        );
    }

    #[test]
    fn detects_unknown_rating_tag_keys() {
        assert!(is_rating_key_name("Unknown(\"RATING\")"));
        assert!(is_rating_key_name("Unknown(\"POPM\")"));
        assert!(is_rating_key_name("POPULARIMETER"));
        assert!(!is_rating_key_name("TITLE"));
    }

    #[test]
    fn parses_common_rating_scales() {
        assert_eq!(parse_rating_text("5"), Some((5, 5)));
        assert_eq!(parse_rating_text("100"), Some((100, 100)));
        assert_eq!(parse_rating_text("255"), Some((100, 100)));
        assert_eq!(parse_rating_text("5/5"), Some((5, 5)));
    }
}
