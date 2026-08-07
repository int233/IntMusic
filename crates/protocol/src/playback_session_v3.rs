use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use crate::PlaybackTransportState;

/// A stable playback session owned by one renderer output.
///
/// V3 commands always address a session and an epoch. A newly elected owner
/// increments the epoch, which prevents delayed commands from a previous
/// connection from changing the current session.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSessionSnapshotV3 {
    pub session_id: Uuid,
    pub zone_id: String,
    pub owner_device_id: String,
    pub epoch: u64,
    pub revision: u64,
    pub event_cursor: u64,
    pub transport: PlaybackTransportState,
    pub current_item_id: Option<Uuid>,
    pub position_ms: u64,
    pub mode: PlaybackSessionModeV3,
    pub shuffle_seed: u64,
    pub queue: Vec<PlaybackQueueItemV3>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_command_id: Option<Uuid>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackRepeatModeV3 {
    #[default]
    Off,
    One,
    All,
}

/// Shuffle and repeat are independent in V3. The legacy protocol combined
/// them into one enum, which made states such as shuffle + repeat-all
/// impossible to represent consistently.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlaybackSessionModeV3 {
    #[serde(default)]
    pub repeat: PlaybackRepeatModeV3,
    #[serde(default)]
    pub shuffle: bool,
    #[serde(default)]
    pub stop_after_current: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlaybackQueueItemV3 {
    /// Stable identity of this queue occurrence. The same track may occur more
    /// than once in a queue, so track_id cannot be used as the item identity.
    pub item_id: Uuid,
    pub track_id: i64,
    pub added_by_device_id: String,
    pub added_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSessionCommandV3 {
    pub command_id: Uuid,
    pub session_id: Uuid,
    pub epoch: u64,
    pub expected_revision: u64,
    pub origin_device_id: String,
    pub issued_at: DateTime<Utc>,
    pub action: PlaybackSessionActionV3,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PlaybackSessionActionV3 {
    Play {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        item_id: Option<Uuid>,
        #[serde(default)]
        position_ms: u64,
    },
    Pause,
    Stop,
    Seek {
        position_ms: u64,
    },
    Next {
        #[serde(default)]
        automatic: bool,
    },
    Previous,
    ReplaceQueue {
        items: Vec<PlaybackQueueItemV3>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        start_item_id: Option<Uuid>,
    },
    AddQueueItems {
        items: Vec<PlaybackQueueItemV3>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before_item_id: Option<Uuid>,
    },
    MoveQueueItem {
        item_id: Uuid,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        before_item_id: Option<Uuid>,
    },
    RemoveQueueItem {
        item_id: Uuid,
    },
    SetMode {
        mode: PlaybackSessionModeV3,
    },
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackCommandStatusV3 {
    Received,
    Applied,
    Duplicate,
    Rejected,
    Conflict,
}

/// Idempotent command result. Duplicate command IDs return the original
/// applied revision instead of executing the action again.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackCommandAckV3 {
    pub command_id: Uuid,
    pub session_id: Uuid,
    pub epoch: u64,
    pub status: PlaybackCommandStatusV3,
    pub applied_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snapshot: Option<PlaybackSessionSnapshotV3>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSessionEventV3 {
    pub cursor: u64,
    pub event_id: Uuid,
    pub session_id: Uuid,
    pub epoch: u64,
    pub revision: u64,
    pub event_type: String,
    pub payload: Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlaybackSessionResumeRequestV3 {
    pub device_id: String,
    pub session_id: Uuid,
    pub known_epoch: u64,
    pub known_revision: u64,
    pub after_cursor: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlaybackSessionResumeV3 {
    pub snapshot: PlaybackSessionSnapshotV3,
    pub events: Vec<PlaybackSessionEventV3>,
    pub has_more: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_is_serialized_as_a_tagged_command() {
        let action = PlaybackSessionActionV3::Next { automatic: true };
        let value = serde_json::to_value(action).expect("serialize action");

        assert_eq!(value["type"], "next");
        assert_eq!(value["automatic"], true);
    }

    #[test]
    fn mode_defaults_to_sequential_repeat_off() {
        let mode: PlaybackSessionModeV3 =
            serde_json::from_str("{}").expect("deserialize default mode");

        assert_eq!(mode, PlaybackSessionModeV3::default());
    }
}
