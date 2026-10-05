use super::*;

pub(crate) type ApiResult<T> = Result<Json<T>, ApiError>;

#[derive(Debug)]
pub(crate) struct ApiError(pub(crate) anyhow::Error);

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self(error)
    }
}

impl From<std::io::Error> for ApiError {
    fn from(error: std::io::Error) -> Self {
        Self(error.into())
    }
}

impl From<reqwest::Error> for ApiError {
    fn from(error: reqwest::Error) -> Self {
        Self(error.into())
    }
}

impl From<axum::extract::multipart::MultipartError> for ApiError {
    fn from(error: axum::extract::multipart::MultipartError) -> Self {
        Self(error.into())
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        if let Some(error) = self.0.downcast_ref::<core_db::CollectionError>() {
            let status = match error.code {
                "collection_protected" | "collection_management_disabled" => StatusCode::FORBIDDEN,
                "collection_conflict" | "collection_retry" => StatusCode::CONFLICT,
                "collection_not_found" => StatusCode::NOT_FOUND,
                "collection_result_expired" => StatusCode::GONE,
                _ => StatusCode::UNPROCESSABLE_ENTITY,
            };
            return (status,Json(json!({"code":error.code,"error":error.message,"current_revision":error.current_revision}))).into_response();
        }
        error!(error = %self.0, "api error");
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ApiErrorBody {
                error: self.0.to_string(),
            }),
        )
            .into_response()
    }
}
