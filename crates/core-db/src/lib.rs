use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use protocol::{
    AlbumDetail, AlbumSummary, ArtistAsset, ArtistDetail, ArtistProfile, ArtistSummary,
    ArtistVisual, ArtistVisualRegion, AudioMasterSummary, CatalogRecordingSummary,
    CatalogWorkSummary, ClientLibraryFileBinding, ClientLibraryManifestRequest,
    ClientLibraryManifestResult, ClientLibraryRootStatus, ClientMutationBatchRequest,
    ClientMutationBatchResult, ClientSyncChange, ClientTrackManifest, CreateDistributionRequest,
    DistributionContentSource, DistributionJobSummary, DistributionSourceTaskAssignment,
    DistributionTaskAssignment, DistributionTaskProgress, DistributionTranscodeTask, LibraryCounts,
    LibraryRoot, LyricPayload, MediaReplicaSummary, MediaVariantSummary, NewPlaylist,
    PlaybackEvent, PlaybackMode, PlaybackQueue, PlaybackQueueItem, PlaybackSession, PlaybackStats,
    PlaylistDetail, PlaylistKind, PlaylistSummary, PlaylistTrackMutation, RecordingLinkCandidate,
    RelatedReleaseTrackSummary, ReleaseEditionSummary, ReplacePlaybackQueue, ScanProblem,
    TrackDetail, TrackEditSnapshot, TrackFavoriteUpdate, TrackMediaProfile, TrackMetadataField,
    TrackMetadataUpdate, TrackPlaybackStat, TrackSummary, UpdateArtistAsset, UpdateArtistProfile,
    UpdateArtistVisual, UpdatePlaylist, VolumeControlMode, ZoneVolume,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha384};
use sqlx::{
    migrate::Migrator,
    sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous},
    QueryBuilder, Row, Sqlite, SqlitePool,
};
use tracing::warn;
use uuid::Uuid;

pub type DbPool = SqlitePool;

static MIGRATOR: Migrator = sqlx::migrate!("./src/migrations");

mod artists;
mod client_library;
mod connection;
mod distribution_jobs;
mod distribution_sources;
mod distribution_transcode;
mod helpers;
mod history;
mod ingest;
mod library_roots;
mod metadata;
mod playback_queue;
mod playlists;
mod track_edit;
mod tracks;

pub(crate) use artists::trimmed_option;
pub use artists::*;
pub use client_library::*;
pub use connection::*;
pub use distribution_jobs::*;
pub use distribution_sources::*;
pub use distribution_transcode::*;
pub use helpers::*;
pub use history::*;
pub(crate) use ingest::*;
pub use library_roots::*;
pub(crate) use metadata::*;
pub use playback_queue::*;
pub use playlists::*;
pub use track_edit::*;
pub use tracks::*;

#[cfg(test)]
mod tests;
