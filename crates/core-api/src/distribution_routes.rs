use super::*;

#[derive(Debug, Deserialize)]
pub(crate) struct DistributionListQuery {
    target_device_id: Option<String>,
    limit: Option<u32>,
}

pub(crate) async fn list_distributions(
    State(state): State<AppState>,
    Query(query): Query<DistributionListQuery>,
) -> ApiResult<Vec<protocol::DistributionJobSummary>> {
    Ok(Json(
        core_db::list_distribution_jobs(
            state.pool(),
            query.target_device_id.as_deref(),
            query.limit.unwrap_or(100),
        )
        .await?,
    ))
}

pub(crate) async fn create_distribution(
    State(state): State<AppState>,
    Json(mut payload): Json<CreateDistributionRequest>,
) -> ApiResult<protocol::DistributionJobSummary> {
    let profile = state.inner.transcoder.profile(&payload.quality)?;
    payload.quality = profile.id().to_string();
    let job = core_db::create_distribution_job(state.pool(), &payload).await?;
    state.emit("distribution.created", &job);
    Ok(Json(job))
}

pub(crate) async fn transcoding_status(
    State(state): State<AppState>,
) -> ApiResult<protocol::TranscodingStatus> {
    Ok(Json(state.inner.transcoder.status().await))
}

#[derive(Debug, Deserialize)]
pub(crate) struct DistributionDeviceQuery {
    device_id: String,
}

pub(crate) async fn next_distribution_task(
    State(state): State<AppState>,
    Query(query): Query<DistributionDeviceQuery>,
) -> ApiResult<Option<protocol::DistributionTaskAssignment>> {
    let task = core_db::claim_distribution_task(state.pool(), &query.device_id).await?;
    if let Some(task) = &task {
        state.emit(
            "distribution.task_claimed",
            json!({
                "job_id": task.job_id,
                "task_id": task.id,
                "device_id": query.device_id,
            }),
        );
    }
    Ok(Json(task))
}

pub(crate) async fn next_distribution_source_task(
    State(state): State<AppState>,
    Query(query): Query<DistributionDeviceQuery>,
) -> ApiResult<Option<protocol::DistributionSourceTaskAssignment>> {
    let task = core_db::claim_distribution_source_task(state.pool(), &query.device_id).await?;
    if let Some(task) = &task {
        state.emit(
            "distribution.source_task_claimed",
            json!({
                "job_id": task.job_id,
                "task_id": task.id,
                "device_id": query.device_id,
            }),
        );
    }
    Ok(Json(task))
}

pub(crate) async fn upload_distribution_source(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
    Query(query): Query<DistributionDeviceQuery>,
    headers: HeaderMap,
    body: Body,
) -> ApiResult<protocol::DistributionJobSummary> {
    let expectation =
        core_db::distribution_source_upload_expectation(state.pool(), &task_id, &query.device_id)
            .await?;
    let safe_extension = expectation
        .extension
        .trim()
        .trim_start_matches('.')
        .to_ascii_lowercase();
    let safe_extension = if safe_extension.is_empty()
        || !safe_extension
            .chars()
            .all(|value| value.is_ascii_alphanumeric())
    {
        "bin".to_string()
    } else {
        safe_extension
    };
    let directory = state.inner.paths.cache_dir.join("distribution-sources");
    tokio::fs::create_dir_all(&directory).await?;
    let temporary = directory.join(format!(".{task_id}.part"));
    let destination = directory.join(format!("{task_id}.{safe_extension}"));

    let receive_result =
        receive_distribution_source(body, &headers, &temporary, expectation.expected_size_bytes)
            .await;
    let actual_size = match receive_result {
        Ok(size) => size,
        Err(error) => {
            let _ = tokio::fs::remove_file(&temporary).await;
            let _ = core_db::fail_distribution_source_task(
                state.pool(),
                &task_id,
                &query.device_id,
                true,
                &format!("{error:#}"),
            )
            .await;
            return Err(ApiError(error));
        }
    };
    let hash_path = temporary.clone();
    let actual_hash =
        match tokio::task::spawn_blocking(move || transcoder::quick_hash(&hash_path)).await {
            Ok(Ok(hash)) => hash,
            Ok(Err(error)) => {
                let _ = tokio::fs::remove_file(&temporary).await;
                let _ = core_db::fail_distribution_source_task(
                    state.pool(),
                    &task_id,
                    &query.device_id,
                    true,
                    &format!("{error:#}"),
                )
                .await;
                return Err(ApiError(error));
            }
            Err(error) => {
                let error = anyhow::anyhow!("source verification worker failed: {error}");
                let _ = tokio::fs::remove_file(&temporary).await;
                let _ = core_db::fail_distribution_source_task(
                    state.pool(),
                    &task_id,
                    &query.device_id,
                    true,
                    &error.to_string(),
                )
                .await;
                return Err(ApiError(error));
            }
        };
    if expectation
        .expected_quick_hash
        .as_deref()
        .is_some_and(|expected| !expected.eq_ignore_ascii_case(&actual_hash))
    {
        let error = anyhow::anyhow!("uploaded source failed its content verification");
        let _ = tokio::fs::remove_file(&temporary).await;
        let _ = core_db::fail_distribution_source_task(
            state.pool(),
            &task_id,
            &query.device_id,
            false,
            &error.to_string(),
        )
        .await;
        return Err(ApiError(error));
    }
    if tokio::fs::metadata(&destination).await.is_ok() {
        tokio::fs::remove_file(&destination).await?;
    }
    tokio::fs::rename(&temporary, &destination).await?;
    let job = match core_db::complete_distribution_source_task(
        state.pool(),
        &task_id,
        &query.device_id,
        &destination,
        actual_size,
        &actual_hash,
    )
    .await
    {
        Ok(job) => job,
        Err(error) => {
            let _ = tokio::fs::remove_file(&destination).await;
            return Err(ApiError(error));
        }
    };
    state.emit("distribution.updated", &job);
    Ok(Json(job))
}

pub(crate) async fn report_distribution_source_task(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
    Json(payload): Json<DistributionTaskProgress>,
) -> ApiResult<protocol::DistributionJobSummary> {
    if payload.state.trim() != "failed" {
        return Err(ApiError(anyhow::anyhow!(
            "source task progress only accepts the failed state"
        )));
    }
    let job = core_db::fail_distribution_source_task(
        state.pool(),
        &task_id,
        &payload.device_id,
        payload.retryable,
        payload
            .error
            .as_deref()
            .unwrap_or("Client source upload failed"),
    )
    .await?;
    state.emit("distribution.updated", &job);
    Ok(Json(job))
}

pub(crate) async fn receive_distribution_source(
    body: Body,
    headers: &HeaderMap,
    temporary: &FsPath,
    expected_size: i64,
) -> Result<i64> {
    if expected_size < 0 {
        anyhow::bail!("source size cannot be negative");
    }
    if let Some(content_length) = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<i64>().ok())
    {
        if content_length != expected_size {
            anyhow::bail!(
                "source Content-Length {content_length} does not match expected size {expected_size}"
            );
        }
    }
    let mut file = tokio::fs::File::create(temporary).await?;
    let mut received = 0_i64;
    let mut stream = body.into_data_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|error| anyhow::anyhow!("source upload failed: {error}"))?;
        received = received
            .checked_add(i64::try_from(chunk.len()).unwrap_or(i64::MAX))
            .context("source upload size overflow")?;
        if received > expected_size {
            anyhow::bail!("uploaded source exceeds expected size {expected_size}");
        }
        file.write_all(&chunk).await?;
    }
    file.flush().await?;
    file.sync_all().await?;
    if received != expected_size {
        anyhow::bail!(
            "uploaded source size {received} does not match expected size {expected_size}"
        );
    }
    Ok(received)
}

pub(crate) async fn report_distribution_task(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
    Json(payload): Json<DistributionTaskProgress>,
) -> ApiResult<protocol::DistributionJobSummary> {
    let update_state = payload.state.clone();
    let job = core_db::update_distribution_task(state.pool(), &task_id, &payload).await?;
    state.emit(
        "distribution.updated",
        json!({
            "job": job,
            "task_id": task_id,
            "task_state": update_state,
        }),
    );
    if matches!(
        job.state.as_str(),
        "completed" | "completed_with_errors" | "cancelled"
    ) {
        cleanup_distribution_relay_sources(&state, &job.id).await;
    }
    Ok(Json(job))
}

pub(crate) async fn distribution_task_content(
    State(state): State<AppState>,
    Path(task_id): Path<String>,
    Query(query): Query<DistributionDeviceQuery>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let source =
        core_db::distribution_content_source(state.pool(), &task_id, &query.device_id).await?;
    stream_file_response(PathBuf::from(source.path), &source.extension, &headers).await
}

pub(crate) async fn cancel_distribution(
    State(state): State<AppState>,
    Path(job_id): Path<String>,
) -> ApiResult<protocol::DistributionJobSummary> {
    let job = core_db::cancel_distribution_job(state.pool(), &job_id).await?;
    state.emit("distribution.updated", &job);
    cleanup_distribution_relay_sources(&state, &job.id).await;
    Ok(Json(job))
}

pub(crate) fn start_distribution_transcode_worker(state: AppState) {
    let worker_count = state.inner.transcoder.max_concurrent_jobs();
    let prune_state = state.clone();
    tokio::spawn(async move {
        prune_transcode_cache(&prune_state).await;
    });
    for worker_index in 0..worker_count {
        let state = state.clone();
        tokio::spawn(async move {
            loop {
                let claimed = {
                    let _guard = state.inner.distribution_claim_gate.lock().await;
                    core_db::claim_distribution_transcode_task(state.pool()).await
                };
                match claimed {
                    Ok(Some(task)) => {
                        let profile = match state.inner.transcoder.profile(&task.quality) {
                            Ok(profile) if profile != TranscodeProfile::Original => profile,
                            Ok(_) => {
                                let _ = core_db::fail_distribution_transcode_task(
                                state.pool(),
                                &task.id,
                                false,
                                "an original-quality item was incorrectly queued for transcoding",
                            )
                            .await;
                                continue;
                            }
                            Err(error) => {
                                if let Ok(job) = core_db::fail_distribution_transcode_task(
                                    state.pool(),
                                    &task.id,
                                    false,
                                    &error.to_string(),
                                )
                                .await
                                {
                                    state.emit("distribution.updated", &job);
                                }
                                continue;
                            }
                        };
                        state.emit(
                            "distribution.transcoding",
                            json!({
                                "job_id": task.job_id,
                                "task_id": task.id,
                                "quality": profile.id(),
                            }),
                        );
                        match state
                            .inner
                            .transcoder
                            .transcode(
                                FsPath::new(&task.source_path),
                                &task.source_signature,
                                profile,
                            )
                            .await
                        {
                            Ok(result) => {
                                match core_db::complete_distribution_transcode_task(
                                    state.pool(),
                                    &task.id,
                                    &result.path,
                                    &result.extension,
                                    result.size_bytes,
                                    &result.quick_hash,
                                )
                                .await
                                {
                                    Ok(job) => {
                                        state.emit("distribution.updated", &job);
                                        remove_distribution_relay_path(
                                            &state,
                                            FsPath::new(&task.source_path),
                                        )
                                        .await;
                                        prune_transcode_cache(&state).await;
                                    }
                                    Err(error) => error!(
                                        task_id = %task.id,
                                        %error,
                                        "failed to publish a completed distribution transcode"
                                    ),
                                }
                            }
                            Err(error) => {
                                let message = format!("{error:#}");
                                error!(
                                    task_id = %task.id,
                                    %message,
                                    "distribution transcode failed"
                                );
                                if let Ok(job) = core_db::fail_distribution_transcode_task(
                                    state.pool(),
                                    &task.id,
                                    true,
                                    &message,
                                )
                                .await
                                {
                                    state.emit("distribution.updated", &job);
                                    if job.state == "completed_with_errors" {
                                        remove_distribution_relay_path(
                                            &state,
                                            FsPath::new(&task.source_path),
                                        )
                                        .await;
                                    }
                                }
                            }
                        }
                    }
                    Ok(None) => tokio::time::sleep(Duration::from_secs(2)).await,
                    Err(error) => {
                        error!(%error, "distribution transcode worker failed to claim a task");
                        tokio::time::sleep(Duration::from_secs(5)).await;
                    }
                }
            }
        });
        info!(worker_index, "distribution transcode worker started");
    }
}

pub(crate) async fn prune_transcode_cache(state: &AppState) {
    match core_db::active_distribution_content_paths(state.pool()).await {
        Ok(paths) => {
            let protected = paths.into_iter().map(PathBuf::from).collect();
            if let Err(error) = state.inner.transcoder.prune_cache(&protected).await {
                error!(%error, "failed to prune the transcode cache");
            }
        }
        Err(error) => error!(%error, "failed to list protected transcode cache paths"),
    }
}

pub(crate) async fn cleanup_distribution_relay_sources(state: &AppState, job_id: &str) {
    match core_db::distribution_content_paths_for_job(state.pool(), job_id).await {
        Ok(paths) => {
            for path in paths {
                remove_distribution_relay_path(state, FsPath::new(&path)).await;
            }
        }
        Err(error) => error!(%error, %job_id, "failed to list distribution relay sources"),
    }
}

pub(crate) async fn remove_distribution_relay_path(state: &AppState, path: &FsPath) {
    let relay_dir = state.inner.paths.cache_dir.join("distribution-sources");
    if path.parent() != Some(relay_dir.as_path()) {
        return;
    }
    if let Err(error) = tokio::fs::remove_file(path).await {
        if error.kind() != std::io::ErrorKind::NotFound {
            error!(%error, path = %path.display(), "failed to remove distribution relay source");
        }
    }
}
