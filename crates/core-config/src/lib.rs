use std::{
    fs,
    net::SocketAddr,
    path::{Path, PathBuf},
    str::FromStr,
};

use anyhow::{Context, Result};
use directories::ProjectDirs;
use serde::{Deserialize, Serialize};

pub const DEFAULT_BIND: &str = "0.0.0.0:49330";
pub const DEFAULT_PORT_RANGE_START: u16 = 49330;
pub const DEFAULT_PORT_RANGE_END: u16 = 49360;
const LEGACY_DEFAULT_BIND: &str = "127.0.0.1:9330";

#[derive(Debug, Clone)]
pub struct CorePaths {
    pub config_file: PathBuf,
    pub data_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub database_file: PathBuf,
}

impl CorePaths {
    pub fn discover(
        config_override: Option<PathBuf>,
        data_dir_override: Option<PathBuf>,
    ) -> Result<Self> {
        let project_dirs = ProjectDirs::from("dev", "intmusic", "LocalMusicCore")
            .context("could not discover user config/data directories")?;

        let config_file =
            config_override.unwrap_or_else(|| project_dirs.config_dir().join("config.toml"));
        let data_dir =
            data_dir_override.unwrap_or_else(|| project_dirs.data_local_dir().to_path_buf());
        let cache_dir = data_dir.join("cache");
        let database_file = data_dir.join("library.sqlite3");

        Ok(Self {
            config_file,
            data_dir,
            cache_dir,
            database_file,
        })
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CoreConfig {
    pub server: ServerConfig,
    pub library: LibraryConfig,
    pub metadata: MetadataConfig,
    pub scan: ScanConfig,
    pub search: SearchConfig,
    pub playback: PlaybackConfig,
    pub favorites: FavoritesConfig,
    pub cache: CacheConfig,
    pub logging: LoggingConfig,
    pub auth: AuthConfig,
}

impl CoreConfig {
    pub fn load_or_create(paths: &CorePaths) -> Result<Self> {
        if paths.config_file.exists() {
            let text = fs::read_to_string(&paths.config_file)
                .with_context(|| format!("failed to read {}", paths.config_file.display()))?;
            let mut config: Self = toml::from_str(&text)
                .with_context(|| format!("failed to parse {}", paths.config_file.display()))?;
            if config.normalize_defaults() {
                config.save(paths)?;
            }
            return Ok(config);
        }

        if let Some(parent) = paths.config_file.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }

        let config = Self::default();
        let text = toml::to_string_pretty(&config).context("failed to serialize default config")?;
        fs::write(&paths.config_file, text)
            .with_context(|| format!("failed to write {}", paths.config_file.display()))?;
        Ok(config)
    }

    pub fn save(&self, paths: &CorePaths) -> Result<()> {
        if let Some(parent) = paths.config_file.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        let text = toml::to_string_pretty(self).context("failed to serialize config")?;
        fs::write(&paths.config_file, text)
            .with_context(|| format!("failed to write {}", paths.config_file.display()))?;
        Ok(())
    }

    pub fn bind_addr(&self) -> Result<SocketAddr> {
        SocketAddr::from_str(&self.server.bind)
            .with_context(|| format!("invalid server.bind {}", self.server.bind))
    }

    fn normalize_defaults(&mut self) -> bool {
        let mut changed = false;
        if self.server.bind == LEGACY_DEFAULT_BIND {
            self.server.bind = DEFAULT_BIND.to_string();
            changed = true;
        }
        if self.server.port_range_end < self.server.port_range_start {
            self.server.port_range_start = DEFAULT_PORT_RANGE_START;
            self.server.port_range_end = DEFAULT_PORT_RANGE_END;
            changed = true;
        }
        changed
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ServerConfig {
    pub alias: Option<String>,
    pub bind: String,
    pub api_prefix: String,
    pub allow_lan: bool,
    pub allow_remote: bool,
    pub auto_port: bool,
    pub port_range_start: u16,
    pub port_range_end: u16,
    pub advertise_mdns: bool,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            alias: Some("Core local".to_string()),
            bind: DEFAULT_BIND.to_string(),
            api_prefix: "/api/v1".to_string(),
            allow_lan: true,
            allow_remote: false,
            auto_port: true,
            port_range_start: DEFAULT_PORT_RANGE_START,
            port_range_end: DEFAULT_PORT_RANGE_END,
            advertise_mdns: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryConfig {
    pub roots: Vec<PathBuf>,
    pub extensions: Vec<String>,
}

impl Default for LibraryConfig {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            extensions: vec!["mp3".to_string(), "flac".to_string()],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetadataConfig {
    pub source: String,
    pub split_text_fields: bool,
    pub artist_separators: Vec<String>,
    pub genre_separators: Vec<String>,
    pub do_not_split_slash: bool,
    pub prefer_original_date: bool,
    pub write_back_tags: bool,
}

impl Default for MetadataConfig {
    fn default() -> Self {
        Self {
            source: "file_tags".to_string(),
            split_text_fields: true,
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
            do_not_split_slash: true,
            prefer_original_date: true,
            write_back_tags: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanConfig {
    pub watch_filesystem: bool,
    pub scan_on_startup: bool,
    pub parallelism: usize,
    pub compute_full_hash_idle: bool,
}

impl Default for ScanConfig {
    fn default() -> Self {
        Self {
            watch_filesystem: false,
            scan_on_startup: false,
            parallelism: 4,
            compute_full_hash_idle: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchConfig {
    pub enable_fts: bool,
    pub enable_cjk_ngram: bool,
    pub index_lyrics: bool,
}

impl Default for SearchConfig {
    fn default() -> Self {
        Self {
            enable_fts: true,
            enable_cjk_ngram: true,
            index_lyrics: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaybackConfig {
    pub default_mode: String,
    pub exclusive_mode: bool,
    pub software_volume: bool,
    pub replaygain: String,
    pub crossfade_seconds: u32,
}

impl Default for PlaybackConfig {
    fn default() -> Self {
        Self {
            default_mode: "direct".to_string(),
            exclusive_mode: false,
            software_volume: false,
            replaygain: "off".to_string(),
            crossfade_seconds: 0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FavoritesConfig {
    pub treat_max_rating_as_favorite: bool,
    pub write_rating_on_favorite: bool,
}

impl Default for FavoritesConfig {
    fn default() -> Self {
        Self {
            treat_max_rating_as_favorite: true,
            write_rating_on_favorite: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CacheConfig {
    pub cover_thumb_sizes: Vec<u32>,
    pub max_cover_cache_mb: u64,
}

impl Default for CacheConfig {
    fn default() -> Self {
        Self {
            cover_thumb_sizes: vec![256, 512],
            max_cover_cache_mb: 2048,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoggingConfig {
    pub level: String,
}

impl Default for LoggingConfig {
    fn default() -> Self {
        Self {
            level: "info".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuthConfig {
    pub pairing_enabled: bool,
    pub token_expire_days: u32,
}

impl Default for AuthConfig {
    fn default() -> Self {
        Self {
            pairing_enabled: true,
            token_expire_days: 365,
        }
    }
}

pub fn ensure_runtime_dirs(paths: &CorePaths) -> Result<()> {
    for path in [&paths.data_dir, &paths.cache_dir] {
        fs::create_dir_all(path).with_context(|| format!("failed to create {}", path.display()))?;
    }
    Ok(())
}

pub fn normalize_config_path(path: impl AsRef<Path>) -> PathBuf {
    path.as_ref().to_path_buf()
}
