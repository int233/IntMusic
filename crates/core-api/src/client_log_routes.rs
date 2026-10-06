use super::*;
use tokio::io::AsyncWriteExt;

const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;
type LogResult = Result<Json<serde_json::Value>, (StatusCode, String)>;
fn invalid(message: &str) -> (StatusCode, String) {
    (StatusCode::BAD_REQUEST, message.into())
}
fn io_error(error: std::io::Error) -> (StatusCode, String) {
    error!(%error, "client diagnostic storage failed");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "diagnostic storage unavailable".into(),
    )
}
fn validate_id(id: &str) -> Result<(), (StatusCode, String)> {
    if id.is_empty()
        || id.len() > 160
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(invalid("invalid client id"));
    }
    Ok(())
}
#[derive(Deserialize)]
pub(crate) struct LogBatch {
    events: Vec<serde_json::Value>,
}
#[derive(Default, Deserialize)]
pub(crate) struct LogQuery {
    limit: Option<usize>,
    level: Option<String>,
    after: Option<String>,
}

pub(crate) async fn append_client_logs(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(batch): Json<LogBatch>,
) -> LogResult {
    validate_id(&id)?;
    if batch.events.is_empty() || batch.events.len() > 32 {
        return Err(invalid("expected 1 to 32 events"));
    }
    let mut payload = String::new();
    for event in batch.events {
        if !event.is_object() || !event["event"].is_string() || !event["timestamp"].is_string() {
            return Err(invalid("events require event and timestamp strings"));
        }
        let line = event.to_string();
        if line.len() > 16384 {
            return Err(invalid("event exceeds 16 KiB"));
        }
        payload.push_str(&line);
        payload.push('\n');
    }
    if payload.len() > 128 * 1024 {
        return Err(invalid("batch exceeds 128 KiB"));
    }
    let _guard = state.inner.client_log_gate.lock().await;
    let dir = state.inner.paths.data_dir.join("client-logs");
    tokio::fs::create_dir_all(&dir).await.map_err(io_error)?;
    let file = dir.join(format!("{id}.jsonl"));
    if !tokio::fs::try_exists(&file).await.map_err(io_error)? {
        let mut entries = tokio::fs::read_dir(&dir).await.map_err(io_error)?;
        let mut count = 0;
        while let Some(entry) = entries.next_entry().await.map_err(io_error)? {
            if entry.path().extension().is_some_and(|e| e == "jsonl") {
                count += 1;
            }
        }
        if count >= 128 {
            return Err((
                StatusCode::INSUFFICIENT_STORAGE,
                "client log capacity reached".into(),
            ));
        }
    }
    if tokio::fs::metadata(&file)
        .await
        .map(|m| m.len())
        .unwrap_or(0)
        + payload.len() as u64
        > MAX_FILE_BYTES
    {
        let previous = dir.join(format!("{id}.previous"));
        if tokio::fs::try_exists(&previous).await.map_err(io_error)? {
            tokio::fs::remove_file(&previous).await.map_err(io_error)?;
        }
        tokio::fs::rename(&file, previous).await.map_err(io_error)?;
    }
    let mut output = tokio::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(file)
        .await
        .map_err(io_error)?;
    output
        .write_all(payload.as_bytes())
        .await
        .map_err(io_error)?;
    Ok(Json(json!({"accepted": payload.lines().count()})))
}

pub(crate) async fn read_client_logs(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Query(query): Query<LogQuery>,
) -> LogResult {
    validate_id(&id)?;
    let _guard = state.inner.client_log_gate.lock().await;
    let dir = state.inner.paths.data_dir.join("client-logs");
    let mut events = std::collections::VecDeque::new();
    let limit = query.limit.unwrap_or(100).clamp(1, 500);
    for suffix in ["previous", "jsonl"] {
        let file = dir.join(format!("{id}.{suffix}"));
        let text = match tokio::fs::read_to_string(file).await {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(io_error(e)),
        };
        for line in text.lines() {
            let Ok(event) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            if query
                .level
                .as_ref()
                .is_some_and(|level| event["level"].as_str() != Some(level))
            {
                continue;
            }
            if query
                .after
                .as_ref()
                .is_some_and(|after| event["timestamp"].as_str().unwrap_or("") <= after.as_str())
            {
                continue;
            }
            if events.len() == limit {
                events.pop_front();
            }
            events.push_back(event);
        }
    }
    Ok(Json(json!({"client_id": id, "events": events})))
}

pub(crate) async fn list_client_logs(State(state): State<AppState>) -> LogResult {
    let dir = state.inner.paths.data_dir.join("client-logs");
    let mut entries = match tokio::fs::read_dir(dir).await {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Json(json!({"clients": []})))
        }
        Err(e) => return Err(io_error(e)),
    };
    let mut clients = Vec::new();
    while let Some(entry) = entries.next_entry().await.map_err(io_error)? {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "jsonl") {
            clients.push(path.file_stem().unwrap().to_string_lossy().into_owned());
        }
    }
    clients.sort();
    Ok(Json(json!({"clients": clients})))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn logs_survive_router_restart_are_isolated_filtered_and_bounded() {
        let (state, dir) = crate::playback_v3_routes::lifecycle_tests::state().await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let router = build_router(state.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        });
        let base = format!("http://{address}/api/v1/diagnostics/clients");
        let client = reqwest::Client::new();
        let events = json!({"events": [
            {"event":"slow", "timestamp":"2026-10-06T01:00:00Z", "level":"info"},
            {"event":"timeout", "timestamp":"2026-10-06T01:00:01Z", "level":"error"}
        ]});
        assert_eq!(
            client
                .post(format!("{base}/a306/logs"))
                .json(&events)
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        let all: serde_json::Value = client
            .get(&base)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(all["clients"], json!(["a306"]));
        let filtered: serde_json::Value = client
            .get(format!("{base}/a306/logs?level=error&limit=1"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(filtered["events"][0]["event"], "timeout");
        let other: serde_json::Value = client
            .get(format!("{base}/phone/logs"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(other["events"], json!([]));
        assert_eq!(
            client
                .post(format!("{base}/a306/logs"))
                .json(&json!({"events":vec![json!({});33]}))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            client
                .post(format!("{base}/a306/logs"))
                .header("content-type", "application/json")
                .body("x".repeat(129 * 1024))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );
        server.abort();
        // A new router/handler reads the existing disk log, not process memory.
        let saved = read_client_logs(
            State(state.clone()),
            Path("a306".into()),
            Query(LogQuery {
                limit: Some(1),
                ..Default::default()
            }),
        )
        .await
        .unwrap();
        assert_eq!(saved.0["events"].as_array().unwrap().len(), 1);
        let path = state.inner.paths.data_dir.join("client-logs/a306.jsonl");
        tokio::fs::write(&path, " ".repeat(MAX_FILE_BYTES as usize))
            .await
            .unwrap();
        let accepted = append_client_logs(
            State(state.clone()),
            Path("a306".into()),
            Json(serde_json::from_value(events).unwrap()),
        )
        .await
        .unwrap();
        assert_eq!(accepted.0["accepted"], 2);
        assert!(tokio::fs::metadata(&path).await.unwrap().len() < MAX_FILE_BYTES);
        assert!(tokio::fs::try_exists(path.with_extension("previous"))
            .await
            .unwrap());
        state.pool().close().await;
        tokio::fs::remove_dir_all(dir).await.unwrap();
    }

    #[test]
    fn client_ids_cannot_escape_log_directory() {
        for id in ["", "../core", "/tmp/file", "a/b", "a.b"] {
            assert!(validate_id(id).is_err());
        }
        assert!(validate_id("flutter-android-A306").is_ok());
    }
}
