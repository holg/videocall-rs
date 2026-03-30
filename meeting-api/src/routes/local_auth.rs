//! Local email/password authentication route handlers.
//!
//! Provides invite-based account creation (admin-only), account activation
//! (user sets password), and email+password login.

use argon2::password_hash::SaltString;
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::{
    extract::State,
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::db::local_auth as db_local_auth;
use crate::error::AppError;
use crate::state::AppState;
use crate::token;

use super::oauth::build_session_cookie;

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct CreateInviteRequest {
    pub email: String,
    pub name: String,
}

#[derive(Serialize)]
pub struct InviteResponse {
    pub user_id: String,
    pub email: String,
    pub invite_token: String,
    pub invite_expires_at: i64,
}

#[derive(Deserialize)]
pub struct ActivateRequest {
    pub invite_token: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct ActivateResponse {
    pub user_id: String,
    pub email: String,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct LoginResponse {
    pub user_id: String,
    pub name: String,
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `POST /admin/users` — Admin creates an invite for a new user.
///
/// Requires `X-Admin-Secret` header matching the `ADMIN_SECRET` env var.
pub async fn create_invite(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<CreateInviteRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), AppError> {
    // Check admin secret
    let expected = state.admin_secret.as_deref().ok_or_else(|| {
        AppError::new(
            StatusCode::NOT_FOUND,
            videocall_meeting_types::APIError {
                code: "NOT_FOUND".into(),
                message: "endpoint not configured".into(),
                engineering_error: None,
            },
        )
    })?;

    let provided = headers
        .get("x-admin-secret")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    if provided != expected {
        return Err(AppError::unauthorized_msg("invalid admin secret"));
    }

    let email = body.email.trim().to_lowercase();
    if email.is_empty() {
        return Err(AppError::new(
            StatusCode::BAD_REQUEST,
            videocall_meeting_types::APIError {
                code: "BAD_REQUEST".into(),
                message: "email is required".into(),
                engineering_error: None,
            },
        ));
    }

    let user_id = Uuid::new_v4().to_string();
    let invite_token = Uuid::new_v4().to_string();
    let invite_expires_at = Utc::now() + Duration::days(7);

    let row = db_local_auth::create_invite(
        &state.db,
        &user_id,
        &email,
        &body.name,
        &invite_token,
        invite_expires_at,
    )
    .await?;

    let resp = InviteResponse {
        user_id: row.id,
        email: row.email,
        invite_token: row.invite_token,
        invite_expires_at: row.invite_expires_at.timestamp(),
    };

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "success": true, "result": resp })),
    ))
}

/// `POST /auth/activate` — User sets their password using an invite token.
pub async fn activate(
    State(state): State<AppState>,
    Json(body): Json<ActivateRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    if body.password.len() < 8 {
        return Err(AppError::new(
            StatusCode::BAD_REQUEST,
            videocall_meeting_types::APIError {
                code: "BAD_REQUEST".into(),
                message: "password must be at least 8 characters".into(),
                engineering_error: None,
            },
        ));
    }

    // Hash the password
    let salt = SaltString::generate(&mut rand::rngs::OsRng);
    let hash = Argon2::default()
        .hash_password(body.password.as_bytes(), &salt)
        .map_err(|e| AppError::internal(&format!("password hash error: {e}")))?
        .to_string();

    let row = db_local_auth::activate_user(&state.db, &body.invite_token, &hash).await?;

    match row {
        Some(user) => Ok(Json(serde_json::json!({
            "success": true,
            "result": ActivateResponse {
                user_id: user.id,
                email: user.email,
            }
        }))),
        None => Err(AppError::new(
            StatusCode::NOT_FOUND,
            videocall_meeting_types::APIError {
                code: "INVALID_TOKEN".into(),
                message: "invite token is invalid, expired, or already used".into(),
                engineering_error: None,
            },
        )),
    }
}

/// `POST /auth/login` — Email + password login, returns session JWT cookie.
pub async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> Result<Response, AppError> {
    let email = body.email.trim().to_lowercase();

    let user = db_local_auth::find_by_email(&state.db, &email)
        .await?
        .ok_or_else(|| AppError::unauthorized_msg("invalid email or password"))?;

    let stored_hash = user
        .password_hash
        .as_deref()
        .ok_or_else(|| AppError::unauthorized_msg("account not activated"))?;

    // Verify password
    let parsed_hash = PasswordHash::new(stored_hash)
        .map_err(|e| AppError::internal(&format!("stored hash parse error: {e}")))?;

    Argon2::default()
        .verify_password(body.password.as_bytes(), &parsed_hash)
        .map_err(|_| AppError::unauthorized_msg("invalid email or password"))?;

    // Generate session JWT (sub = UUID, not email)
    let session_jwt = token::generate_session_token(
        &state.jwt_secret,
        &user.id,
        &user.name,
        state.session_ttl_secs,
    )?;

    // Update last_login (fire-and-forget)
    let _ = db_local_auth::update_last_login(&state.db, &user.id).await;

    // Build response with Set-Cookie header
    let cookie = build_session_cookie(
        &state.cookie_name,
        &session_jwt,
        state.session_ttl_secs,
        state.cookie_domain.as_deref(),
        state.cookie_secure,
    );

    let resp_body = serde_json::json!({
        "success": true,
        "result": LoginResponse {
            user_id: user.id,
            name: user.name,
        }
    });

    let mut response = (StatusCode::OK, Json(resp_body)).into_response();
    response.headers_mut().insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&cookie).expect("valid cookie header"),
    );

    Ok(response)
}
