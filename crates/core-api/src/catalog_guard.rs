use super::*;
use axum::{extract::Request, middleware::Next};

const SERVER_HEADER: &str = "x-intmusic-server-id";
const EPOCH_HEADER: &str = "x-intmusic-catalog-epoch";

#[derive(Clone)]
pub(crate) struct CatalogGuard {
    server_id: String,
    epoch: String,
}

impl CatalogGuard {
    pub(crate) fn for_state(state: &AppState) -> Self {
        Self {
            server_id: state.inner.server_id.to_string(),
            epoch: state.inner.catalog_epoch.clone(),
        }
    }

    fn validate(&self, headers: &HeaderMap) -> Result<(), StatusCode> {
        // Old clients remain compatible. Clients opting in must send both fields;
        // a malformed/partial fence must never silently become an unguarded write.
        if !headers.contains_key(SERVER_HEADER) && !headers.contains_key(EPOCH_HEADER) {
            return Ok(());
        }
        if headers.get_all(SERVER_HEADER).iter().count() != 1
            || headers.get_all(EPOCH_HEADER).iter().count() != 1
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        let server = headers[SERVER_HEADER]
            .to_str()
            .map_err(|_| StatusCode::BAD_REQUEST)?;
        let epoch = headers[EPOCH_HEADER]
            .to_str()
            .map_err(|_| StatusCode::BAD_REQUEST)?;
        if server != self.server_id || epoch != self.epoch {
            return Err(StatusCode::CONFLICT);
        }
        Ok(())
    }
}

pub(crate) async fn guard_catalog_request(
    State(guard): State<CatalogGuard>,
    request: Request,
    next: Next,
) -> Response {
    let system_path = request.uri().path().contains("/collections")
        || request.uri().path().contains("/home-layout");
    if system_path
        && request.method() != axum::http::Method::GET
        && (!request.headers().contains_key(SERVER_HEADER)
            || !request.headers().contains_key(EPOCH_HEADER))
    {
        return (StatusCode::CONFLICT, Json(json!({"code":"catalog_identity_mismatch","error":"Collection writes require server and catalog identity headers"}))).into_response();
    }
    match guard.validate(request.headers()) {
        Ok(()) => next.run(request).await,
        Err(status) => (
            status,
            Json(json!({
                "error": "Catalog identity changed or request identity is incomplete; refresh /status before retrying",
                "code": "catalog_identity_mismatch",
            })),
        )
            .into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guard() -> CatalogGuard {
        CatalogGuard {
            server_id: "server-a".into(),
            epoch: "epoch-2".into(),
        }
    }

    fn headers(server: &str, epoch: &str) -> HeaderMap {
        let mut result = HeaderMap::new();
        result.insert(SERVER_HEADER, HeaderValue::from_str(server).unwrap());
        result.insert(EPOCH_HEADER, HeaderValue::from_str(epoch).unwrap());
        result
    }

    #[test]
    fn catalog_guard_preserves_legacy_clients() {
        assert_eq!(guard().validate(&HeaderMap::new()), Ok(()));
    }

    #[test]
    fn catalog_guard_accepts_matching_identity() {
        assert_eq!(guard().validate(&headers("server-a", "epoch-2")), Ok(()));
    }

    #[test]
    fn catalog_guard_rejects_same_address_replacement_and_epoch_reset() {
        assert_eq!(
            guard().validate(&headers("server-b", "epoch-2")),
            Err(StatusCode::CONFLICT)
        );
        assert_eq!(
            guard().validate(&headers("server-a", "epoch-1")),
            Err(StatusCode::CONFLICT)
        );
    }

    #[test]
    fn catalog_guard_rejects_partial_and_duplicate_identity() {
        let mut partial = headers("server-a", "epoch-2");
        partial.remove(EPOCH_HEADER);
        assert_eq!(guard().validate(&partial), Err(StatusCode::BAD_REQUEST));
        let mut duplicate = headers("server-a", "epoch-2");
        duplicate.append(EPOCH_HEADER, HeaderValue::from_static("epoch-1"));
        assert_eq!(guard().validate(&duplicate), Err(StatusCode::BAD_REQUEST));
    }

    #[tokio::test]
    async fn catalog_guard_runs_before_mutating_handler() {
        let writes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let handler_writes = writes.clone();
        let router = Router::new()
            .route(
                "/write",
                post(move || async move {
                    handler_writes.fetch_add(1, Ordering::SeqCst);
                    StatusCode::NO_CONTENT
                }),
            )
            .layer(axum::middleware::from_fn_with_state(
                guard(),
                guard_catalog_request,
            ));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let stale = client
            .post(format!("http://{address}/write"))
            .header(SERVER_HEADER, "server-a")
            .header(EPOCH_HEADER, "epoch-old")
            .send()
            .await
            .unwrap();
        assert_eq!(stale.status(), StatusCode::CONFLICT);
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        let accepted = client
            .post(format!("http://{address}/write"))
            .header(SERVER_HEADER, "server-a")
            .header(EPOCH_HEADER, "epoch-2")
            .send()
            .await
            .unwrap();
        assert_eq!(accepted.status(), StatusCode::NO_CONTENT);
        assert_eq!(writes.load(Ordering::SeqCst), 1);
        server.abort();
    }
}
