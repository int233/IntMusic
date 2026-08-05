use protocol::{
    PlaybackQueueItemV3, PlaybackRepeatModeV3, PlaybackSessionModeV3, PlaybackSessionSnapshotV3,
};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueAdvanceV3 {
    Select(Uuid),
    Stop,
}

/// Pure queue transition logic shared by every Core-owned playback session.
///
/// The renderer persists the resulting selected item together with the session
/// revision before loading media. Network availability is deliberately absent
/// from this model: online and offline transitions must produce the same item.
pub fn next_item(snapshot: &PlaybackSessionSnapshotV3, automatic: bool) -> QueueAdvanceV3 {
    if snapshot.queue.is_empty() || (automatic && snapshot.mode.stop_after_current) {
        return QueueAdvanceV3::Stop;
    }

    if automatic
        && snapshot.mode.repeat == PlaybackRepeatModeV3::One
        && snapshot.current_item_id.is_some()
    {
        return QueueAdvanceV3::Select(snapshot.current_item_id.expect("checked above"));
    }

    let order = playback_order(&snapshot.queue, snapshot.mode, snapshot.shuffle_seed);
    let Some(current_item_id) = snapshot.current_item_id else {
        return order
            .first()
            .copied()
            .map_or(QueueAdvanceV3::Stop, QueueAdvanceV3::Select);
    };
    let Some(cursor) = order.iter().position(|item_id| *item_id == current_item_id) else {
        return order
            .first()
            .copied()
            .map_or(QueueAdvanceV3::Stop, QueueAdvanceV3::Select);
    };

    if let Some(item_id) = order.get(cursor + 1) {
        return QueueAdvanceV3::Select(*item_id);
    }
    if snapshot.mode.repeat == PlaybackRepeatModeV3::All {
        return QueueAdvanceV3::Select(order[0]);
    }
    QueueAdvanceV3::Stop
}

pub fn previous_item(snapshot: &PlaybackSessionSnapshotV3) -> QueueAdvanceV3 {
    if snapshot.queue.is_empty() {
        return QueueAdvanceV3::Stop;
    }

    let order = playback_order(&snapshot.queue, snapshot.mode, snapshot.shuffle_seed);
    let Some(current_item_id) = snapshot.current_item_id else {
        return QueueAdvanceV3::Select(*order.last().expect("non-empty order"));
    };
    let Some(cursor) = order.iter().position(|item_id| *item_id == current_item_id) else {
        return QueueAdvanceV3::Select(order[0]);
    };

    if let Some(previous) = cursor.checked_sub(1).and_then(|index| order.get(index)) {
        return QueueAdvanceV3::Select(*previous);
    }
    if snapshot.mode.repeat == PlaybackRepeatModeV3::All {
        return QueueAdvanceV3::Select(*order.last().expect("non-empty order"));
    }
    QueueAdvanceV3::Select(current_item_id)
}

pub fn playback_order(
    queue: &[PlaybackQueueItemV3],
    mode: PlaybackSessionModeV3,
    shuffle_seed: u64,
) -> Vec<Uuid> {
    let mut order = queue.iter().map(|item| item.item_id).collect::<Vec<_>>();
    if mode.shuffle {
        order.sort_by_key(|item_id| shuffle_key(*item_id, shuffle_seed));
    }
    order
}

fn shuffle_key(item_id: Uuid, seed: u64) -> u64 {
    let bytes = item_id.as_bytes();
    let high = u64::from_be_bytes(bytes[..8].try_into().expect("UUID high bytes"));
    let low = u64::from_be_bytes(bytes[8..].try_into().expect("UUID low bytes"));
    splitmix64(high ^ low ^ seed.wrapping_mul(0x9E37_79B9_7F4A_7C15))
}

fn splitmix64(mut value: u64) -> u64 {
    value ^= value >> 30;
    value = value.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    value ^= value >> 27;
    value = value.wrapping_mul(0x94D0_49BB_1331_11EB);
    value ^ (value >> 31)
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use protocol::{PlaybackSessionSnapshotV3, PlaybackTransportState};

    use super::*;

    fn item(value: u128, track_id: i64) -> PlaybackQueueItemV3 {
        PlaybackQueueItemV3 {
            item_id: Uuid::from_u128(value),
            track_id,
            added_by_device_id: "client-a".to_string(),
            added_at: Utc.timestamp_opt(0, 0).single().expect("epoch"),
        }
    }

    fn snapshot(mode: PlaybackSessionModeV3) -> PlaybackSessionSnapshotV3 {
        PlaybackSessionSnapshotV3 {
            session_id: Uuid::from_u128(100),
            zone_id: "renderer:client-a:default".to_string(),
            owner_device_id: "client-a".to_string(),
            epoch: 4,
            revision: 9,
            event_cursor: 12,
            transport: PlaybackTransportState::Playing,
            current_item_id: Some(Uuid::from_u128(2)),
            position_ms: 0,
            mode,
            shuffle_seed: 42,
            queue: vec![item(1, 101), item(2, 102), item(3, 103)],
            last_command_id: None,
            updated_at: Utc.timestamp_opt(0, 0).single().expect("epoch"),
        }
    }

    #[test]
    fn sequential_queue_stops_at_the_end() {
        let mut state = snapshot(PlaybackSessionModeV3::default());
        state.current_item_id = Some(Uuid::from_u128(3));

        assert_eq!(next_item(&state, true), QueueAdvanceV3::Stop);
    }

    #[test]
    fn repeat_one_only_repeats_automatic_advances() {
        let state = snapshot(PlaybackSessionModeV3 {
            repeat: PlaybackRepeatModeV3::One,
            ..PlaybackSessionModeV3::default()
        });

        assert_eq!(
            next_item(&state, true),
            QueueAdvanceV3::Select(Uuid::from_u128(2))
        );
        assert_eq!(
            next_item(&state, false),
            QueueAdvanceV3::Select(Uuid::from_u128(3))
        );
    }

    #[test]
    fn shuffle_order_is_stable_for_a_seed() {
        let state = snapshot(PlaybackSessionModeV3 {
            shuffle: true,
            repeat: PlaybackRepeatModeV3::All,
            ..PlaybackSessionModeV3::default()
        });

        assert_eq!(
            playback_order(&state.queue, state.mode, state.shuffle_seed),
            playback_order(&state.queue, state.mode, state.shuffle_seed)
        );
        assert_ne!(
            playback_order(&state.queue, state.mode, state.shuffle_seed),
            playback_order(&state.queue, state.mode, state.shuffle_seed + 1)
        );
    }

    #[test]
    fn repeat_all_wraps_in_both_directions() {
        let mut state = snapshot(PlaybackSessionModeV3 {
            repeat: PlaybackRepeatModeV3::All,
            ..PlaybackSessionModeV3::default()
        });
        state.current_item_id = Some(Uuid::from_u128(3));
        assert_eq!(
            next_item(&state, true),
            QueueAdvanceV3::Select(Uuid::from_u128(1))
        );

        state.current_item_id = Some(Uuid::from_u128(1));
        assert_eq!(
            previous_item(&state),
            QueueAdvanceV3::Select(Uuid::from_u128(3))
        );
    }
}
