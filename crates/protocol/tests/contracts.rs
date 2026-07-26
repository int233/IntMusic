use std::collections::BTreeSet;

use protocol::{VolumeControlMode, ZoneVolume, ZoneVolumeUpdate};

#[test]
fn openapi_documents_every_registered_http_path() {
    let router = include_str!("../../core-api/src/router.rs");
    let openapi = include_str!("../openapi.yaml");

    let registered = route_literals(router);
    let documented = openapi
        .lines()
        .filter_map(|line| {
            let path = line.strip_prefix("  /")?.strip_suffix(':')?;
            Some(format!("/{path}"))
        })
        .collect::<BTreeSet<_>>();

    let missing = registered.difference(&documented).collect::<Vec<_>>();
    let stale = documented.difference(&registered).collect::<Vec<_>>();
    assert!(
        missing.is_empty() && stale.is_empty(),
        "OpenAPI route drift detected; missing={missing:?}, stale={stale:?}"
    );
}

#[test]
fn dual_layer_volume_payloads_accept_legacy_clients() {
    let update: ZoneVolumeUpdate =
        serde_json::from_str(r#"{"volume":0.42,"muted":false}"#).expect("legacy update");
    assert_eq!(update.mode, VolumeControlMode::Player);

    let state: ZoneVolume =
        serde_json::from_str(r#"{"zone_id":"client:default","volume":0.42,"muted":false}"#)
            .expect("legacy volume state");
    assert_eq!(state.mode, VolumeControlMode::Player);
    assert_eq!(state.player_volume, 1.0);
    assert!(!state.player_muted);
    assert_eq!(state.system_volume, None);
    assert_eq!(state.system_muted, None);
}

#[test]
fn event_schema_covers_every_emitted_literal() {
    let schema = include_str!("../events.schema.json");
    let sources = [
        include_str!("../../core-api/src/lib.rs"),
        include_str!("../../core-api/src/events.rs"),
        include_str!("../../core-api/src/artist_routes.rs"),
        include_str!("../../core-api/src/sync_routes.rs"),
        include_str!("../../core-api/src/track_routes.rs"),
        include_str!("../../core-api/src/distribution_routes.rs"),
        include_str!("../../core-api/src/playback_service.rs"),
        include_str!("../../core-api/src/settings_routes.rs"),
        include_str!("../../core-api/src/renderer_routes.rs"),
        include_str!("../../core-api/src/server.rs"),
    ];
    let mut emitted = BTreeSet::new();
    for source in sources {
        emitted.extend(string_argument_literals(source, ".emit("));
        emitted.extend(string_argument_literals(source, "EventEnvelope::new("));
    }
    let missing = emitted
        .iter()
        .filter(|event| !schema.contains(&format!("\"{event}\"")))
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "event schema is missing emitted event types: {missing:?}"
    );
}

fn route_literals(source: &str) -> BTreeSet<String> {
    source
        .split(".route(")
        .skip(1)
        .filter_map(|tail| {
            let quote = tail.find('"')?;
            let value = &tail[quote + 1..];
            let end = value.find('"')?;
            Some(value[..end].to_string())
        })
        .collect()
}

fn string_argument_literals(source: &str, call: &str) -> BTreeSet<String> {
    source
        .split(call)
        .skip(1)
        .filter_map(|tail| {
            let quote = tail.find('"')?;
            let value = &tail[quote + 1..];
            let end = value.find('"')?;
            let literal = &value[..end];
            literal.contains('.').then(|| literal.to_string())
        })
        .collect()
}
