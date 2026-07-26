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
    let mut command_rx = state.inner.renderer_commands.subscribe();
    let mut event_rx = state.inner.events.subscribe();

    loop {
        tokio::select! {
            biased;
            command = command_rx.recv() => {
                match command {
                    Ok(command) => {
                        if renderer_id.as_deref().is_some_and(|renderer_id| {
                            command
                                .payload
                                .get("renderer_id")
                                .and_then(|value| value.as_str())
                                != Some(renderer_id)
                        }) {
                            continue;
                        }
                        if !send_ws_event(&mut sender, &command).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(skipped, "renderer command subscriber lagged");
                        let event = EventEnvelope::new(
                            "renderer.resync_required",
                            json!({ "reason": "command_lag", "skipped": skipped }),
                        );
                        if !send_ws_event(&mut sender, &event).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
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
                        if !send_ws_event(&mut sender, &event).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!(skipped, "event subscriber lagged");
                        let event = EventEnvelope::new(
                            "connection.snapshot_required",
                            json!({ "reason": "event_lag", "skipped": skipped }),
                        );
                        if !send_ws_event(&mut sender, &event).await {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
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
