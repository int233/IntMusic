use super::*;

pub async fn serve(config: CoreConfig, paths: CorePaths, pool: DbPool) -> Result<()> {
    serve_with_shutdown(config, paths, pool, std::future::pending()).await
}

pub async fn serve_with_shutdown<S>(
    config: CoreConfig,
    paths: CorePaths,
    pool: DbPool,
    shutdown: S,
) -> Result<()>
where
    S: Future<Output = ()> + Send + 'static,
{
    let (listener, bind_addr) = bind_core_listener(&config).await?;
    let server_id = Uuid::parse_str(&core_db::sync_server_id(&pool).await?)
        .context("stored Core server ID is invalid")?;
    let catalog_epoch = core_db::catalog_epoch(&pool).await?;
    let runtime_endpoint_file = write_runtime_endpoint(&paths, bind_addr, server_id).await?;
    let discovery_name = core_display_name(&config);
    let discovery_publisher = if config.server.advertise_mdns {
        match DiscoveryPublisher::publish_core(
            &server_id.to_string(),
            &discovery_name,
            bind_addr.port(),
            "v1",
            API_PREFIX,
        ) {
            Ok(publisher) => {
                info!(service = publisher.fullname(), "mDNS discovery published");
                Some(publisher)
            }
            Err(error) => {
                error!(%error, "failed to publish mDNS discovery");
                None
            }
        }
    } else {
        None
    };
    let discovery_service = discovery_publisher
        .as_ref()
        .map(|publisher| publisher.fullname().to_string());
    let transcoder = Transcoder::discover(TranscoderSettings {
        enabled: config.transcoding.enabled,
        ffmpeg_path: config.transcoding.ffmpeg_path.clone(),
        ffprobe_path: config.transcoding.ffprobe_path.clone(),
        cache_dir: paths.cache_dir.join("transcodes"),
        max_cache_bytes: config.transcoding.max_cache_mb.saturating_mul(1024 * 1024),
        max_concurrent_jobs: config.transcoding.max_concurrent_jobs,
    })
    .await;
    let state = AppState::new(
        config,
        paths,
        pool,
        (server_id, catalog_epoch),
        bind_addr,
        discovery_service,
        transcoder,
    );
    state.inner.library_revision.store(
        core_db::sync_cursor(state.pool()).await?.max(1),
        Ordering::SeqCst,
    );
    state.emit("core.ready", json!({ "api_prefix": API_PREFIX }));
    start_renderer_expiry_monitor(state.clone());
    start_local_playback_monitor(state.clone());
    start_distribution_transcode_worker(state.clone());
    let router = build_router(state);
    info!(address = %bind_addr, "local music core listening");
    let _discovery_publisher = discovery_publisher;
    let (shutdown_started_tx, mut shutdown_started_rx) = tokio::sync::watch::channel(false);
    let mut server = Box::pin(
        axum::serve(listener, router)
            .with_graceful_shutdown(async move {
                shutdown.await;
                let _ = shutdown_started_tx.send(true);
            })
            .into_future(),
    );
    let serve_result = tokio::select! {
        result = &mut server => result,
        changed = shutdown_started_rx.changed() => {
            if changed.is_err() || !*shutdown_started_rx.borrow() {
                server.await
            } else {
                match tokio::time::timeout(Duration::from_secs(8), &mut server).await {
                    Ok(result) => result,
                    Err(_) => {
                        warn!(
                            timeout_seconds = 8,
                            "forcing Core shutdown with active connections still open"
                        );
                        Ok(())
                    }
                }
            }
        }
    };
    if let Err(error) = tokio::fs::remove_file(&runtime_endpoint_file).await {
        if error.kind() != std::io::ErrorKind::NotFound {
            error!(
                path = %runtime_endpoint_file.display(),
                %error,
                "failed to remove the runtime endpoint file"
            );
        }
    }
    serve_result?;
    Ok(())
}

async fn write_runtime_endpoint(
    paths: &CorePaths,
    bind_addr: SocketAddr,
    server_id: Uuid,
) -> Result<PathBuf> {
    let local_ip = match bind_addr.ip() {
        IpAddr::V4(ip) if ip.is_unspecified() => IpAddr::V4(Ipv4Addr::LOCALHOST),
        IpAddr::V6(ip) if ip.is_unspecified() => IpAddr::V6(Ipv6Addr::LOCALHOST),
        ip => ip,
    };
    let local_addr = SocketAddr::new(local_ip, bind_addr.port());
    let endpoint_file = paths.data_dir.join("core-endpoint.json");
    let endpoint = serde_json::to_vec_pretty(&json!({
        "base_url": format!("http://{local_addr}"),
        "bind_address": bind_addr.to_string(),
        "server_id": server_id,
        "pid": std::process::id(),
    }))?;
    tokio::fs::write(&endpoint_file, endpoint).await?;
    Ok(endpoint_file)
}

fn start_renderer_expiry_monitor(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
        loop {
            interval.tick().await;
            expire_offline_renderer_playback(&state).await;
        }
    });
}

fn start_local_playback_monitor(state: AppState) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_millis(750));
        loop {
            interval.tick().await;
            for previous in state.inner.playback.cached_states().await {
                if previous.state != PlaybackTransportState::Playing || previous.track_id.is_none()
                {
                    continue;
                }
                let current = state.inner.playback.state_for_zone(&previous.zone_id).await;
                if current.state != PlaybackTransportState::Stopped {
                    continue;
                }
                record_playback_finish(&state, &previous, "completed", "completed", None).await;
                state.emit("playback.state_changed", &current);
                match step_playback_queue_and_emit(&state, &previous.zone_id, false, true).await {
                    Ok(Some(track_id)) => {
                        if let Err(error) = play_track_on_zone(
                            &state,
                            &previous.zone_id,
                            track_id,
                            0,
                            &PlaybackCommandContext::default(),
                        )
                        .await
                        {
                            error!(
                                zone_id = previous.zone_id,
                                %error,
                                "failed to advance the local playback queue"
                            );
                        }
                    }
                    Ok(None) => {}
                    Err(error) => {
                        error!(
                            zone_id = previous.zone_id,
                            %error,
                            "failed to resolve the next local queue item"
                        );
                    }
                }
            }
        }
    });
}

async fn bind_core_listener(config: &CoreConfig) -> Result<(tokio::net::TcpListener, SocketAddr)> {
    let configured_addr = config.bind_addr()?;
    if !config.server.auto_port {
        let listener = tokio::net::TcpListener::bind(configured_addr).await?;
        return Ok((listener, configured_addr));
    }

    let ports = shuffled_ports(config.server.port_range_start, config.server.port_range_end);
    let mut last_error = None;
    for port in ports {
        let addr = SocketAddr::new(configured_addr.ip(), port);
        match tokio::net::TcpListener::bind(addr).await {
            Ok(listener) => return Ok((listener, addr)),
            Err(error) => {
                last_error = Some(error);
            }
        }
    }

    let error = last_error
        .map(|error| error.to_string())
        .unwrap_or_else(|| "empty port range".to_string());
    anyhow::bail!(
        "no available core port in {}-{} on {}: {}",
        config.server.port_range_start,
        config.server.port_range_end,
        configured_addr.ip(),
        error
    )
}

fn shuffled_ports(start: u16, end: u16) -> Vec<u16> {
    if start > end {
        return Vec::new();
    }
    let mut ports = (start..=end).collect::<Vec<_>>();
    let mut seed = u128::from_le_bytes(*Uuid::new_v4().as_bytes());
    for index in (1..ports.len()).rev() {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ports.swap(index, (seed as usize) % (index + 1));
    }
    ports
}
