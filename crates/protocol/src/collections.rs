use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityType {
    Track,
    Album,
    Artist,
    Genre,
}
impl EntityType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Track => "track",
            Self::Album => "album",
            Self::Artist => "artist",
            Self::Genre => "genre",
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CollectionPredicate {
    All {
        conditions: Vec<CollectionPredicate>,
    },
    Any {
        conditions: Vec<CollectionPredicate>,
    },
    Field {
        field: String,
        op: String,
        value: Value,
    },
    Tracks {
        quantifier: TrackQuantifier,
        value: u32,
        role: ArtistTrackRole,
        condition: Box<CollectionPredicate>,
    },
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrackQuantifier {
    Any,
    All,
    AtLeast,
    Percent,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtistTrackRole {
    Performer,
    AlbumArtist,
    Composer,
    Lyricist,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CollectionRefreshPolicy {
    Live,
    Daily,
    Manual,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionSort {
    pub field: String,
    pub descending: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionPlayback {
    pub filter: Option<CollectionPredicate>,
    pub artist_role: ArtistTrackRole,
    pub order: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionDefinition {
    pub name: String,
    pub description: String,
    pub entity_type: EntityType,
    pub cover_album_id: Option<i64>,
    pub included: Vec<i64>,
    pub excluded: Vec<i64>,
    pub automatic: Option<CollectionPredicate>,
    pub sort: Vec<CollectionSort>,
    pub limit: Option<u32>,
    pub refresh: CollectionRefreshPolicy,
    pub max_per_artist: Option<u32>,
    pub max_per_album: Option<u32>,
    pub playback: CollectionPlayback,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionSummary {
    pub id: i64,
    pub name: String,
    pub description: String,
    pub entity_type: EntityType,
    pub cover_album_id: Option<i64>,
    pub system_key: Option<String>,
    pub revision: u64,
    pub result_version: Option<String>,
    pub result_total: u64,
    pub can_edit: bool,
    pub can_delete: bool,
    pub updated_at: DateTime<Utc>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenreSummary {
    pub id: i64,
    pub name: String,
    pub track_count: u64,
    pub album_count: u64,
    pub artist_count: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "entity_type", content = "data", rename_all = "snake_case")]
pub enum CollectionEntity {
    Track(Box<TrackSummary>),
    Album(AlbumSummary),
    Artist(ArtistSummary),
    Genre(GenreSummary),
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionItem {
    pub entity_id: i64,
    #[serde(flatten)]
    pub entity: CollectionEntity,
    pub reason: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionPage {
    pub collection: CollectionSummary,
    pub definition: CollectionDefinition,
    pub result_version: Option<String>,
    pub generated_at: Option<DateTime<Utc>>,
    pub next_refresh_at: Option<DateTime<Utc>>,
    pub matched_total: u64,
    pub result_total: u64,
    pub missing_members: Vec<i64>,
    pub offset: u32,
    pub next_offset: Option<u32>,
    pub items: Vec<CollectionItem>,
    pub error: Option<String>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionWrite {
    pub expected_revision: Option<u64>,
    pub definition: CollectionDefinition,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionRefreshRequest {
    pub expected_result_version: Option<String>,
    pub request_id: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionSettings {
    pub management_enabled: bool,
    pub revision: u64,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionSettingsUpdate {
    pub management_enabled: bool,
    pub expected_revision: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CollectionQueueSource {
    pub collection_id: i64,
    pub result_version: String,
    pub plan_id: String,
    pub name: String,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CollectionPlayRequest {
    pub result_version: String,
    pub entity_ids: Option<Vec<i64>>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectionPlayPlan {
    pub source: CollectionQueueSource,
    pub tracks: Vec<TrackSummary>,
    pub missing_count: u64,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HomeSection {
    pub id: String,
    pub collection_id: Option<i64>,
    pub builtin: Option<String>,
    pub title: Option<String>,
    pub layout: String,
    pub preview_count: u32,
    pub width: String,
    pub hidden: bool,
    pub track_columns: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HomeLayout {
    pub revision: u64,
    pub sections: Vec<HomeSection>,
}
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HomeLayoutUpdate {
    pub expected_revision: u64,
    pub sections: Vec<HomeSection>,
}
