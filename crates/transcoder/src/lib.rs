use std::{
    collections::HashSet,
    env,
    ffi::OsString,
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};

use anyhow::{bail, Context, Result};
use protocol::{TranscodingProfileCapability, TranscodingStatus};
use sha2::{Digest, Sha256};
use tokio::{process::Command, sync::Semaphore};
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct TranscoderSettings {
    pub enabled: bool,
    pub ffmpeg_path: Option<PathBuf>,
    pub ffprobe_path: Option<PathBuf>,
    pub cache_dir: PathBuf,
    pub max_cache_bytes: u64,
    pub max_concurrent_jobs: usize,
}

#[derive(Debug, Clone)]
pub struct TranscodeResult {
    pub path: PathBuf,
    pub extension: String,
    pub size_bytes: i64,
    pub quick_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TranscodeProfile {
    Original,
    Flac,
    Aac256,
    Aac160,
    Aac96,
    Opus160,
    Opus96,
}

impl TranscodeProfile {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "original" => Some(Self::Original),
            "flac" | "lossless" => Some(Self::Flac),
            "aac-256" | "high" => Some(Self::Aac256),
            "aac-160" | "balanced" => Some(Self::Aac160),
            "aac-96" | "data-saver" => Some(Self::Aac96),
            "opus-160" => Some(Self::Opus160),
            "opus-96" => Some(Self::Opus96),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::Flac => "flac",
            Self::Aac256 => "aac-256",
            Self::Aac160 => "aac-160",
            Self::Aac96 => "aac-96",
            Self::Opus160 => "opus-160",
            Self::Opus96 => "opus-96",
        }
    }

    pub fn extension(self) -> Option<&'static str> {
        match self {
            Self::Original => None,
            Self::Flac => Some("flac"),
            Self::Aac256 | Self::Aac160 | Self::Aac96 => Some("m4a"),
            Self::Opus160 | Self::Opus96 => Some("opus"),
        }
    }

    fn capability(
        self,
        encoders: &HashSet<String>,
        engine_error: Option<&str>,
    ) -> TranscodingProfileCapability {
        let (label, codec, container, bitrate_kbps, lossless, encoder) = match self {
            Self::Original => ("Original", "source", "source", None, false, None),
            Self::Flac => ("Lossless FLAC", "flac", "flac", None, true, Some("flac")),
            Self::Aac256 => (
                "High · AAC 256 kbps",
                "aac",
                "m4a",
                Some(256),
                false,
                Some("aac"),
            ),
            Self::Aac160 => (
                "Balanced · AAC 160 kbps",
                "aac",
                "m4a",
                Some(160),
                false,
                Some("aac"),
            ),
            Self::Aac96 => (
                "Data saver · AAC 96 kbps",
                "aac",
                "m4a",
                Some(96),
                false,
                Some("aac"),
            ),
            Self::Opus160 => (
                "Opus 160 kbps",
                "opus",
                "ogg",
                Some(160),
                false,
                Some("libopus"),
            ),
            Self::Opus96 => (
                "Opus 96 kbps",
                "opus",
                "ogg",
                Some(96),
                false,
                Some("libopus"),
            ),
        };
        let available = if self == Self::Original {
            true
        } else {
            engine_error.is_none() && encoder.is_some_and(|value| encoders.contains(value))
        };
        let unavailable_reason = if available {
            None
        } else if let Some(error) = engine_error {
            Some(error.to_string())
        } else {
            Some(format!(
                "FFmpeg encoder {} is unavailable",
                encoder.unwrap_or(codec)
            ))
        };
        TranscodingProfileCapability {
            id: self.id().to_string(),
            label: label.to_string(),
            codec: codec.to_string(),
            container: container.to_string(),
            bitrate_kbps,
            lossless,
            available,
            unavailable_reason,
        }
    }
}

const PROFILES: [TranscodeProfile; 7] = [
    TranscodeProfile::Original,
    TranscodeProfile::Flac,
    TranscodeProfile::Aac256,
    TranscodeProfile::Aac160,
    TranscodeProfile::Aac96,
    TranscodeProfile::Opus160,
    TranscodeProfile::Opus96,
];

#[derive(Clone)]
pub struct Transcoder {
    inner: Arc<TranscoderInner>,
}

struct TranscoderInner {
    enabled: bool,
    ffmpeg: Option<PathBuf>,
    ffprobe: Option<PathBuf>,
    version: Option<String>,
    encoders: HashSet<String>,
    error: Option<String>,
    cache_dir: PathBuf,
    max_cache_bytes: u64,
    max_concurrent_jobs: usize,
    permits: Semaphore,
}

impl Transcoder {
    pub async fn discover(settings: TranscoderSettings) -> Self {
        let max_concurrent_jobs = settings.max_concurrent_jobs.clamp(1, 16);
        let mut ffmpeg = None;
        let mut ffprobe = None;
        let mut version = None;
        let mut encoders = HashSet::new();
        let mut error = None;

        if !settings.enabled {
            error = Some("Transcoding is disabled in Core settings".to_string());
        } else {
            ffmpeg = locate_program(settings.ffmpeg_path.as_deref(), "ffmpeg");
            ffprobe = locate_program(settings.ffprobe_path.as_deref(), "ffprobe")
                .or_else(|| ffmpeg.as_deref().and_then(sibling_ffprobe));
            match ffmpeg.as_deref() {
                None => {
                    error = Some(
                        "Bundled FFmpeg was not found; original-quality delivery remains available"
                            .to_string(),
                    );
                }
                Some(path) => match probe_ffmpeg(path).await {
                    Ok((detected_version, detected_encoders)) => {
                        version = Some(detected_version);
                        encoders = detected_encoders;
                        info!(path = %path.display(), "FFmpeg transcoder is available");
                    }
                    Err(probe_error) => {
                        error = Some(format!("FFmpeg capability check failed: {probe_error:#}"));
                    }
                },
            }
            if error.is_none() && ffprobe.is_none() {
                error = Some("Bundled ffprobe was not found".to_string());
            }
        }

        Self {
            inner: Arc::new(TranscoderInner {
                enabled: settings.enabled,
                ffmpeg,
                ffprobe,
                version,
                encoders,
                error,
                cache_dir: settings.cache_dir,
                max_cache_bytes: settings.max_cache_bytes,
                max_concurrent_jobs,
                permits: Semaphore::new(max_concurrent_jobs),
            }),
        }
    }

    pub fn supports(&self, profile: TranscodeProfile) -> bool {
        if profile == TranscodeProfile::Original {
            return true;
        }
        profile
            .capability(&self.inner.encoders, self.inner.error.as_deref())
            .available
    }

    pub fn profile(&self, value: &str) -> Result<TranscodeProfile> {
        let profile = TranscodeProfile::parse(value)
            .with_context(|| format!("unknown transcoding profile {value}"))?;
        if !self.supports(profile) {
            let capability = profile.capability(&self.inner.encoders, self.inner.error.as_deref());
            bail!(
                "{}",
                capability
                    .unavailable_reason
                    .unwrap_or_else(|| format!("profile {} is unavailable", profile.id()))
            );
        }
        Ok(profile)
    }

    pub fn max_concurrent_jobs(&self) -> usize {
        self.inner.max_concurrent_jobs
    }

    pub async fn status(&self) -> TranscodingStatus {
        let cache_bytes = directory_size(&self.inner.cache_dir).await.unwrap_or(0);
        TranscodingStatus {
            enabled: self.inner.enabled,
            available: self.inner.error.is_none(),
            ffmpeg_path: self
                .inner
                .ffmpeg
                .as_ref()
                .map(|path| path.display().to_string()),
            ffprobe_path: self
                .inner
                .ffprobe
                .as_ref()
                .map(|path| path.display().to_string()),
            version: self.inner.version.clone(),
            error: self.inner.error.clone(),
            max_concurrent_jobs: self.inner.max_concurrent_jobs as u32,
            cache_dir: self.inner.cache_dir.display().to_string(),
            cache_bytes,
            max_cache_bytes: self.inner.max_cache_bytes,
            profiles: PROFILES
                .into_iter()
                .map(|profile| {
                    profile.capability(&self.inner.encoders, self.inner.error.as_deref())
                })
                .collect(),
        }
    }

    pub async fn transcode(
        &self,
        input: &Path,
        source_signature: &str,
        profile: TranscodeProfile,
    ) -> Result<TranscodeResult> {
        if profile == TranscodeProfile::Original {
            bail!("the original profile does not require transcoding");
        }
        if !self.supports(profile) {
            bail!("transcoding profile {} is unavailable", profile.id());
        }
        let ffmpeg = self
            .inner
            .ffmpeg
            .as_ref()
            .context("FFmpeg is unavailable")?;
        let ffprobe = self
            .inner
            .ffprobe
            .as_ref()
            .context("ffprobe is unavailable")?;
        let extension = profile
            .extension()
            .context("profile has no output extension")?;
        let mut cache_hasher = Sha256::new();
        cache_hasher.update(b"intmusic-transcode-v1\0");
        cache_hasher.update(source_signature.as_bytes());
        cache_hasher.update([0]);
        cache_hasher.update(profile.id().as_bytes());
        cache_hasher.update([0]);
        if let Some(version) = &self.inner.version {
            cache_hasher.update(version.as_bytes());
        }
        let cache_key = hex::encode(cache_hasher.finalize());
        let cache_parent = self.inner.cache_dir.join(&cache_key[..2]);
        let output = cache_parent.join(format!("{cache_key}.{extension}"));

        if is_nonempty_file(&output).await {
            return result_for_file(output, extension).await;
        }

        let _permit = self
            .inner
            .permits
            .acquire()
            .await
            .context("transcoder concurrency limiter closed")?;
        if is_nonempty_file(&output).await {
            return result_for_file(output, extension).await;
        }
        tokio::fs::create_dir_all(&cache_parent)
            .await
            .with_context(|| format!("failed to create {}", cache_parent.display()))?;
        let temporary =
            cache_parent.join(format!(".{cache_key}.{}.part.{extension}", Uuid::new_v4()));

        let mut command = Command::new(ffmpeg);
        command
            .arg("-nostdin")
            .arg("-hide_banner")
            .arg("-loglevel")
            .arg("error")
            .arg("-i")
            .arg(input)
            .arg("-map")
            .arg("0:a:0")
            .arg("-map_metadata")
            .arg("0")
            .arg("-vn");
        match profile {
            TranscodeProfile::Flac => {
                command
                    .arg("-c:a")
                    .arg("flac")
                    .arg("-compression_level")
                    .arg("8");
            }
            TranscodeProfile::Aac256 | TranscodeProfile::Aac160 | TranscodeProfile::Aac96 => {
                let bitrate = match profile {
                    TranscodeProfile::Aac256 => "256k",
                    TranscodeProfile::Aac160 => "160k",
                    TranscodeProfile::Aac96 => "96k",
                    _ => unreachable!(),
                };
                command
                    .arg("-c:a")
                    .arg("aac")
                    .arg("-b:a")
                    .arg(bitrate)
                    .arg("-movflags")
                    .arg("+faststart");
            }
            TranscodeProfile::Opus160 | TranscodeProfile::Opus96 => {
                let bitrate = if profile == TranscodeProfile::Opus160 {
                    "160k"
                } else {
                    "96k"
                };
                command
                    .arg("-c:a")
                    .arg("libopus")
                    .arg("-b:a")
                    .arg(bitrate)
                    .arg("-vbr")
                    .arg("on");
            }
            TranscodeProfile::Original => unreachable!(),
        }
        command.arg("-y").arg(&temporary).kill_on_drop(true);
        let output_result =
            match tokio::time::timeout(Duration::from_secs(6 * 60 * 60), command.output()).await {
                Ok(Ok(output)) => output,
                Ok(Err(error)) => {
                    let _ = tokio::fs::remove_file(&temporary).await;
                    return Err(error)
                        .with_context(|| format!("failed to start {}", ffmpeg.display()));
                }
                Err(_) => {
                    let _ = tokio::fs::remove_file(&temporary).await;
                    bail!("FFmpeg timed out");
                }
            };
        if !output_result.status.success() {
            let _ = tokio::fs::remove_file(&temporary).await;
            let stderr = String::from_utf8_lossy(&output_result.stderr);
            bail!(
                "FFmpeg exited with {}: {}",
                output_result.status,
                stderr.trim()
            );
        }
        if let Err(error) = validate_audio(ffprobe, &temporary).await {
            let _ = tokio::fs::remove_file(&temporary).await;
            return Err(error);
        }

        match tokio::fs::rename(&temporary, &output).await {
            Ok(()) => {}
            Err(error) if is_nonempty_file(&output).await => {
                let _ = tokio::fs::remove_file(&temporary).await;
                warn!(%error, path = %output.display(), "another task populated the transcode cache");
            }
            Err(error) => {
                let _ = tokio::fs::remove_file(&temporary).await;
                return Err(error)
                    .with_context(|| format!("failed to publish {}", output.display()));
            }
        }
        let result = result_for_file(output, extension).await?;
        Ok(result)
    }

    pub async fn prune_cache(&self, protected: &HashSet<PathBuf>) -> Result<()> {
        prune_cache(&self.inner.cache_dir, self.inner.max_cache_bytes, protected).await
    }
}

fn locate_program(explicit: Option<&Path>, name: &str) -> Option<PathBuf> {
    if let Some(path) = explicit.filter(|path| path.is_file()) {
        return Some(path.to_path_buf());
    }
    let executable_name = executable_name(name);
    if let Ok(current) = env::current_exe() {
        if let Some(parent) = current.parent() {
            for candidate in [
                parent
                    .join("tools")
                    .join("ffmpeg")
                    .join("bin")
                    .join(&executable_name),
                parent.join("ffmpeg").join("bin").join(&executable_name),
                parent.join(&executable_name),
            ] {
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    env::var_os("PATH").and_then(|path| {
        env::split_paths(&path)
            .map(|directory| directory.join(&executable_name))
            .find(|candidate| candidate.is_file())
    })
}

fn executable_name(name: &str) -> OsString {
    if cfg!(windows) {
        format!("{name}.exe").into()
    } else {
        name.into()
    }
}

fn sibling_ffprobe(ffmpeg: &Path) -> Option<PathBuf> {
    let candidate = ffmpeg.with_file_name(executable_name("ffprobe"));
    candidate.is_file().then_some(candidate)
}

async fn probe_ffmpeg(path: &Path) -> Result<(String, HashSet<String>)> {
    let version_output = Command::new(path)
        .arg("-hide_banner")
        .arg("-version")
        .output()
        .await?;
    if !version_output.status.success() {
        bail!("ffmpeg -version exited with {}", version_output.status);
    }
    let version = String::from_utf8_lossy(&version_output.stdout)
        .lines()
        .next()
        .unwrap_or("FFmpeg")
        .trim()
        .to_string();
    let encoder_output = Command::new(path)
        .arg("-hide_banner")
        .arg("-encoders")
        .output()
        .await?;
    if !encoder_output.status.success() {
        bail!("ffmpeg -encoders exited with {}", encoder_output.status);
    }
    let encoders = String::from_utf8_lossy(&encoder_output.stdout)
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let flags = fields.next()?;
            let name = fields.next()?;
            (flags.len() >= 6 && flags.starts_with('A')).then(|| name.to_string())
        })
        .collect();
    Ok((version, encoders))
}

async fn validate_audio(ffprobe: &Path, path: &Path) -> Result<()> {
    let output = Command::new(ffprobe)
        .arg("-v")
        .arg("error")
        .arg("-select_streams")
        .arg("a:0")
        .arg("-show_entries")
        .arg("stream=codec_name")
        .arg("-of")
        .arg("json")
        .arg(path)
        .output()
        .await?;
    if !output.status.success() {
        bail!(
            "ffprobe rejected the transcode: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let payload: serde_json::Value = serde_json::from_slice(&output.stdout)?;
    let has_audio = payload
        .get("streams")
        .and_then(|streams| streams.as_array())
        .is_some_and(|streams| !streams.is_empty());
    if !has_audio {
        bail!("the transcoded file contains no audio stream");
    }
    Ok(())
}

async fn result_for_file(path: PathBuf, extension: &str) -> Result<TranscodeResult> {
    let metadata = tokio::fs::metadata(&path)
        .await
        .with_context(|| format!("failed to stat {}", path.display()))?;
    let quick_hash_path = path.clone();
    let quick_hash = tokio::task::spawn_blocking(move || quick_hash(&quick_hash_path)).await??;
    Ok(TranscodeResult {
        path,
        extension: extension.to_string(),
        size_bytes: i64::try_from(metadata.len()).unwrap_or(i64::MAX),
        quick_hash,
    })
}

async fn is_nonempty_file(path: &Path) -> bool {
    tokio::fs::metadata(path)
        .await
        .is_ok_and(|metadata| metadata.is_file() && metadata.len() > 0)
}

pub fn quick_hash(path: &Path) -> Result<String> {
    const CHUNK_SIZE: usize = 64 * 1024;
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; CHUNK_SIZE];
    let read = file.read(&mut buffer)?;
    hasher.update(&buffer[..read]);
    if len > CHUNK_SIZE as u64 {
        file.seek(SeekFrom::Start(len.saturating_sub(CHUNK_SIZE as u64)))?;
        let read = file.read(&mut buffer)?;
        hasher.update(&buffer[..read]);
    }
    hasher.update(len.to_le_bytes());
    Ok(hex::encode(hasher.finalize()))
}

async fn directory_size(path: &Path) -> Result<u64> {
    let path = path.to_path_buf();
    tokio::task::spawn_blocking(move || {
        let mut total = 0_u64;
        if !path.exists() {
            return Ok(total);
        }
        let mut pending = vec![path];
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(directory)? {
                let entry = entry?;
                let metadata = entry.metadata()?;
                if metadata.is_dir() {
                    pending.push(entry.path());
                } else if metadata.is_file() {
                    total = total.saturating_add(metadata.len());
                }
            }
        }
        Ok::<_, std::io::Error>(total)
    })
    .await?
    .map_err(Into::into)
}

async fn prune_cache(path: &Path, limit: u64, protected: &HashSet<PathBuf>) -> Result<()> {
    if limit == 0 {
        return Ok(());
    }
    let path = path.to_path_buf();
    let protected = protected.clone();
    tokio::task::spawn_blocking(move || {
        let mut files = Vec::new();
        if !path.exists() {
            return Ok(());
        }
        let mut pending = vec![path];
        while let Some(directory) = pending.pop() {
            for entry in std::fs::read_dir(directory)? {
                let entry = entry?;
                let metadata = entry.metadata()?;
                if metadata.is_dir() {
                    pending.push(entry.path());
                } else if metadata.is_file()
                    && !entry.file_name().to_string_lossy().contains(".part.")
                    && !protected.contains(&entry.path())
                {
                    files.push((
                        entry.path(),
                        metadata.len(),
                        metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
                    ));
                }
            }
        }
        let mut total = files.iter().map(|(_, size, _)| *size).sum::<u64>();
        if total <= limit {
            return Ok(());
        }
        files.sort_by_key(|(_, _, modified)| *modified);
        for (file, size, _) in files {
            if total <= limit {
                break;
            }
            if std::fs::remove_file(&file).is_ok() {
                total = total.saturating_sub(size);
            }
        }
        Ok::<_, std::io::Error>(())
    })
    .await?
    .map_err(Into::into)
}

#[cfg(test)]
mod tests {
    use super::{quick_hash, TranscodeProfile};

    #[test]
    fn aliases_map_to_stable_profile_ids() {
        assert_eq!(TranscodeProfile::parse("balanced").unwrap().id(), "aac-160");
        assert_eq!(
            TranscodeProfile::parse("data-saver").unwrap().extension(),
            Some("m4a")
        );
        assert!(TranscodeProfile::parse("--arbitrary-ffmpeg-args").is_none());
    }

    #[test]
    fn quick_hash_contract_matches_clients() {
        let path =
            std::env::temp_dir().join(format!("intmusic-quick-hash-{}.bin", uuid::Uuid::now_v7()));
        std::fs::write(&path, b"IntMusic quick hash contract").unwrap();
        let actual = quick_hash(&path).unwrap();
        std::fs::remove_file(path).unwrap();
        assert_eq!(
            actual,
            "967bd5c0c116735e4d002a510c015dc91eeaf2edc81f28599cb29a251879c310"
        );
    }
}
