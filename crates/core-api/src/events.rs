use super::*;

#[derive(Debug, Default, Deserialize)]
pub(crate) struct EventsWsQuery {
    renderer_id: Option<String>,
    #[serde(default)]
    after_cursor: u64,
}

pub(crate) async fn events_ws(
    State(state): State<AppState>,
    Query(query): Query<EventsWsQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state, query.renderer_id, query.after_cursor))
}

pub(crate) async fn handle_ws(
    socket: WebSocket,
    state: AppState,
    _renderer_id: Option<String>,
    after_cursor: u64,
) {
    let (mut sender, mut receiver) = socket.split();
    let mut event_rx = state.inner.events.subscribe();
    let mut delivered_cursor = after_cursor;

    match replay_missed_events(&mut sender, &state, delivered_cursor).await {
        Ok(Some(cursor)) => delivered_cursor = cursor,
        Ok(None) => return,
        Err(error) => {
            warn!(%error, after_cursor, "failed to replay Core events");
            let event = EventEnvelope::new(
                "connection.snapshot_required",
                json!({ "reason": "event_replay_failed" }),
            );
            if !send_ws_event(&mut sender, &event).await {
                return;
            }
        }
    }

    loop {
        tokio::select! {
            biased;
            inbound = receiver.next() => {
                match inbound {
                    Some(Ok(Message::Text(text))) => {
                        let Ok(message) = serde_json::from_str::<serde_json::Value>(&text) else {
                            continue;
                        };
                        if message.get("type").and_then(|value| value.as_str())
                            == Some("client.ping")
                        {
                            let event = EventEnvelope::new(
                                "connection.pong",
                                json!({
                                    "ping_id": message.get("ping_id"),
                                    "client_time_ms": message.get("client_time_ms"),
                                    "server_time_ms": Utc::now().timestamp_millis(),
                                }),
                            );
                            if !send_ws_event(&mut sender, &event).await {
                                break;
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        info!(error = %error, "event WebSocket receive failed");
                        break;
                    }
                }
            }
            event = event_rx.recv() => {
                match event {
                    Ok(event) => {
                        let event_cursor = event.cursor.unwrap_or(0);
                        if event_cursor > 0 && event_cursor <= delivered_cursor {
                            continue;
                        }
                        if event_cursor > 0 {
                            delivered_cursor = event_cursor;
                        }
                        if !send_ws_event(&mut sender, &event).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(skipped, "event subscriber lagged");
                        match replay_missed_events(
                            &mut sender,
                            &state,
                            delivered_cursor,
                        ).await {
                            Ok(Some(cursor)) => delivered_cursor = cursor,
                            Ok(None) => break,
                            Err(error) => {
                                warn!(%error, skipped, "failed to recover lagged event subscriber");
                                let event = EventEnvelope::new(
                                    "connection.snapshot_required",
                                    json!({ "reason": "event_lag", "skipped": skipped }),
                                );
                                if !send_ws_event(&mut sender, &event).await {
                                    break;
                                }
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
}

async fn replay_missed_events(
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    state: &AppState,
    mut cursor: u64,
) -> Result<Option<u64>> {
    loop {
        let page = core_db::replay_events(state.pool(), cursor, 500).await?;
        if page.requires_snapshot {
            let event = EventEnvelope::new(
                "connection.snapshot_required",
                json!({ "reason": "event_retention_gap", "after_cursor": cursor }),
            );
            if !send_ws_event(sender, &event).await {
                return Ok(None);
            }
        }
        for event in page.events {
            if !send_ws_event(sender, &event).await {
                return Ok(None);
            }
        }
        cursor = page.scanned_cursor;
        if !page.has_more {
            return Ok(Some(cursor));
        }
    }
}

pub(crate) async fn send_ws_event(
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    event: &EventEnvelope,
) -> bool {
    match serde_json::to_string(event) {
        Ok(text) => {
            match tokio::time::timeout(
                Duration::from_secs(4),
                sender.send(Message::Text(text.into())),
            )
            .await
            {
                Ok(result) => result.is_ok(),
                Err(_) => {
                    warn!(
                        event_type = event.event_type,
                        "closing stalled event WebSocket"
                    );
                    false
                }
            }
        }
        Err(error) => {
            error!(error = %error, "failed to serialize event");
            true
        }
    }
}
