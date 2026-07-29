use super::*;

pub fn build_router(state: AppState) -> Router {
    let api = Router::new()
        .route("/status", get(status))
        .route("/library/roots", get(list_roots).post(add_root))
        .route("/library/roots/{id}", delete(remove_root))
        .route(
            "/library-management/summary",
            get(library_management_summary),
        )
        .route(
            "/library-management/files",
            get(list_library_management_files),
        )
        .route(
            "/library-management/files/actions",
            post(manage_library_files),
        )
        .route(
            "/library-management/tracks/merge/preview",
            post(preview_library_track_merge),
        )
        .route(
            "/library-management/tracks/merge",
            post(merge_library_tracks),
        )
        .route(
            "/library-management/track-merges/{merge_id}/undo",
            post(undo_library_track_merge),
        )
        .route(
            "/library-management/files/{file_id}",
            get(library_management_file_detail),
        )
        .route(
            "/library-management/files/{file_id}/action",
            post(manage_library_file),
        )
        .route(
            "/library-management/devices",
            get(list_library_management_devices),
        )
        .route(
            "/library-management/devices/{device_id}/action",
            post(manage_library_device),
        )
        .route(
            "/library-management/sources/{root_id}/action",
            post(manage_library_source),
        )
        .route(
            "/client-library/manifests",
            get(list_client_library_roots).post(upsert_client_library_manifest),
        )
        .route(
            "/client-library/pending",
            get(list_client_library_pending_files),
        )
        .route(
            "/client-library/files/{file_id}/resolve",
            post(resolve_client_library_file),
        )
        .route(
            "/client-library/devices/{device_id}/roots/{root_external_id}",
            delete(remove_client_library_root),
        )
        .route("/client-sync/mutations", post(apply_client_mutations))
        .route("/client-sync/snapshot", get(client_sync_snapshot))
        .route("/client-sync/changes", get(client_sync_changes))
        .route("/client-sync/details", get(client_sync_details))
        .route(
            "/distributions",
            get(list_distributions).post(create_distribution),
        )
        .route("/distributions/{job_id}/cancel", post(cancel_distribution))
        .route("/distributions/tasks/next", get(next_distribution_task))
        .route(
            "/distributions/tasks/{task_id}/progress",
            post(report_distribution_task),
        )
        .route(
            "/distributions/tasks/{task_id}/content",
            get(distribution_task_content),
        )
        .route(
            "/distributions/source-tasks/next",
            get(next_distribution_source_task),
        )
        .route(
            "/distributions/source-tasks/{task_id}/content",
            put(upload_distribution_source),
        )
        .route(
            "/distributions/source-tasks/{task_id}/progress",
            post(report_distribution_source_task),
        )
        .route("/transcoding/status", get(transcoding_status))
        .route("/scan/start", post(start_scan))
        .route("/scan/problems", get(scan_problems))
        .route("/albums", get(list_albums))
        .route("/albums/{album_id}", get(album_detail))
        .route("/artists", get(list_artists))
        .route(
            "/artists/{artist_id}",
            get(artist_detail).post(update_artist_profile),
        )
        .route(
            "/artists/{artist_id}/musicbrainz/preview",
            post(musicbrainz_artist_preview),
        )
        .route(
            "/artists/{artist_id}/assets",
            get(list_artist_assets).post(upload_artist_assets),
        )
        .route(
            "/artists/{artist_id}/assets/{asset_id}",
            post(update_artist_asset).delete(delete_artist_asset),
        )
        .route(
            "/artists/{artist_id}/visuals/{slot}",
            post(update_artist_visual),
        )
        .route("/tracks", get(list_tracks))
        .route("/tracks/{track_id}", get(track_detail))
        .route(
            "/tracks/{track_id}/edit",
            get(track_edit_snapshot).post(update_track_metadata),
        )
        .route("/tracks/{track_id}/waveform", get(track_waveform))
        .route("/tracks/{track_id}/media", get(track_media_profile))
        .route(
            "/tracks/{track_id}/recording/candidates",
            get(track_recording_candidates),
        )
        .route(
            "/tracks/{track_id}/recording/link",
            post(link_track_recording),
        )
        .route(
            "/tracks/{track_id}/recording/detach",
            post(detach_track_recording),
        )
        .route("/tracks/{track_id}/favorite", post(update_track_favorite))
        .route("/tracks/{track_id}/lyrics", get(track_lyrics))
        .route("/tracks/{track_id}/stream", get(track_stream))
        .route("/artwork/albums/{album_id}", get(album_artwork))
        .route("/artwork/tracks/{track_id}", get(track_artwork))
        .route("/artwork/artists/{artist_id}/{slot}", get(artist_artwork))
        .route("/search", get(search))
        .route("/playlists", get(list_playlists).post(create_playlist))
        .route(
            "/playlists/{playlist_id}",
            get(get_playlist)
                .post(update_playlist)
                .delete(delete_playlist),
        )
        .route("/playlists/{playlist_id}/tracks", post(add_playlist_track))
        .route(
            "/playlists/{playlist_id}/tracks/{track_id}",
            delete(remove_playlist_track),
        )
        .route("/outputs", get(list_outputs))
        .route("/renderers", get(list_renderers))
        .route("/renderers/register", post(register_renderer))
        .route("/renderers/{client_id}/state", post(report_renderer_state))
        .route(
            "/renderers/{client_id}/volume-state",
            post(report_renderer_volume_state),
        )
        .route("/zones", get(list_zones))
        .route("/zones/play-many", post(play_many_zones))
        .route("/zones/{zone_id}/play", post(play_zone))
        .route(
            "/zones/{zone_id}/play-collection",
            post(play_zone_collection),
        )
        .route("/zones/{zone_id}/pause", post(pause_zone))
        .route("/zones/{zone_id}/stop", post(stop_zone))
        .route("/zones/{zone_id}/seek", post(seek_zone))
        .route(
            "/zones/{zone_id}/queue",
            get(get_zone_queue).post(replace_zone_queue),
        )
        .route("/zones/{zone_id}/queue/items", post(add_zone_queue_items))
        .route(
            "/zones/{zone_id}/queue/items/{item_id}",
            delete(remove_zone_queue_item),
        )
        .route("/zones/{zone_id}/queue/move", post(move_zone_queue_item))
        .route("/zones/{zone_id}/queue/mode", post(update_zone_queue_mode))
        .route("/zones/{zone_id}/next", post(next_zone_track))
        .route("/zones/{zone_id}/previous", post(previous_zone_track))
        .route(
            "/zones/{zone_id}/volume",
            get(get_zone_volume).post(update_zone_volume),
        )
        .route("/zones/{zone_id}/alias", post(update_zone_alias))
        .route("/zones/{zone_id}/transfer", post(transfer_zone))
        .route("/playback/history", get(playback_history))
        .route("/playback/sessions", get(playback_sessions))
        .route("/playback/stats", get(playback_stats))
        .route("/settings", get(settings))
        .route(
            "/settings/server",
            get(server_settings).post(update_server_settings),
        )
        .route(
            "/settings/favorites",
            get(favorite_settings).post(update_favorite_settings),
        )
        .route(
            "/settings/metadata",
            get(metadata_settings).post(update_metadata_settings),
        )
        .route("/diagnostics", get(diagnostics));

    Router::new()
        .nest(API_PREFIX, api)
        .route(EVENTS_WS_PATH, get(events_ws))
        .layer(CompressionLayer::new())
        .layer(CorsLayer::permissive())
        .layer(TraceLayer::new_for_http())
        .layer(DefaultBodyLimit::max(256 * 1024 * 1024))
        .with_state(state)
}
