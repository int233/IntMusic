use super::*;

#[derive(Debug, Default, Deserialize)]
pub(crate) struct EventsWsQuery {
    renderer_id: Option<String>,
}

pub(crate) async fn events_ws(
    State(state): State<AppState>,
    Query(query): Query<EventsWsQuery>,
    ws: WebSocketUpgrade,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, state, query.renderer_id))
}

pub(crate) async fn handle_ws(socket: WebSocket, state: AppState, renderer_id: Option<String>) {
    let (mut sender, mut receiver) = socket.split();
    let mut event_rx = state.inner.events.subscribe();
    // Playback commands and transport reports are ephemeral. Reconnection
    // restores the current snapshot; it never re-executes historical commands.
    let mut delivered_cursor = state.inner.event_cursor.load(Ordering::SeqCst);
    if !send_snapshot_required(&mut sender, delivered_cursor, "connected").await {
        return;
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
                        if !event_is_for_renderer(&event, renderer_id.as_deref()) { continue; }
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
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        delivered_cursor = state.inner.event_cursor.load(Ordering::SeqCst);
                        if !send_snapshot_required(&mut sender, delivered_cursor, "event_lag").await { break; }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
}

fn event_is_for_renderer(event: &EventEnvelope, renderer_id: Option<&str>) -> bool {
    event.event_type != "renderer.command"
        || event.payload.get("renderer_id").and_then(|v| v.as_str()) == renderer_id
}

async fn send_snapshot_required(
    sender: &mut futures_util::stream::SplitSink<WebSocket, Message>,
    cursor: u64,
    reason: &str,
) -> bool {
    send_ws_event(
        sender,
        &EventEnvelope::new(
            "connection.snapshot_required",
            json!({"reason": reason, "event_cursor": cursor}),
        ),
    )
    .await
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn renderer_commands_are_delivered_only_to_their_decoder_owner() {
        let command = EventEnvelope::new("renderer.command", json!({"renderer_id": "mac"}));
        assert!(event_is_for_renderer(&command, Some("mac")));
        assert!(!event_is_for_renderer(&command, Some("phone")));
        assert!(!event_is_for_renderer(&command, None));
        let state = EventEnvelope::new("playback.state_changed", json!({}));
        assert!(event_is_for_renderer(&state, Some("phone")));
    }
}
