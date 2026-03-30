//! Local user authentication queries (PostgreSQL).

use chrono::{DateTime, Utc};

use crate::db::{DbPool, LocalUserRow};

/// Create a new invited user.
pub async fn create_invite(
    pool: &DbPool,
    id: &str,
    email: &str,
    name: &str,
    invite_token: &str,
    invite_expires_at: DateTime<Utc>,
) -> Result<LocalUserRow, sqlx::Error> {
    sqlx::query_as::<_, LocalUserRow>(
        r#"
        INSERT INTO local_users (id, email, name, invite_token, invite_expires_at)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, email, name, password_hash, invite_token, invite_expires_at,
                  activated_at, created_at, last_login
        "#,
    )
    .bind(id)
    .bind(email)
    .bind(name)
    .bind(invite_token)
    .bind(invite_expires_at)
    .fetch_one(pool)
    .await
}

/// Find a pending (not yet activated, not expired) invite by token.
pub async fn find_by_invite_token(
    pool: &DbPool,
    invite_token: &str,
) -> Result<Option<LocalUserRow>, sqlx::Error> {
    sqlx::query_as::<_, LocalUserRow>(
        r#"
        SELECT id, email, name, password_hash, invite_token, invite_expires_at,
               activated_at, created_at, last_login
        FROM local_users
        WHERE invite_token = $1 AND activated_at IS NULL AND invite_expires_at > NOW()
        "#,
    )
    .bind(invite_token)
    .fetch_optional(pool)
    .await
}

/// Activate a user account by setting their password.
pub async fn activate_user(
    pool: &DbPool,
    invite_token: &str,
    password_hash: &str,
) -> Result<Option<LocalUserRow>, sqlx::Error> {
    sqlx::query_as::<_, LocalUserRow>(
        r#"
        UPDATE local_users
        SET password_hash = $2, activated_at = NOW()
        WHERE invite_token = $1 AND activated_at IS NULL
        RETURNING id, email, name, password_hash, invite_token, invite_expires_at,
                  activated_at, created_at, last_login
        "#,
    )
    .bind(invite_token)
    .bind(password_hash)
    .fetch_optional(pool)
    .await
}

/// Find an activated user by email (for login).
pub async fn find_by_email(
    pool: &DbPool,
    email: &str,
) -> Result<Option<LocalUserRow>, sqlx::Error> {
    sqlx::query_as::<_, LocalUserRow>(
        r#"
        SELECT id, email, name, password_hash, invite_token, invite_expires_at,
               activated_at, created_at, last_login
        FROM local_users
        WHERE email = $1 AND activated_at IS NOT NULL
        "#,
    )
    .bind(email)
    .fetch_optional(pool)
    .await
}

/// Update last_login timestamp.
pub async fn update_last_login(pool: &DbPool, id: &str) -> Result<(), sqlx::Error> {
    sqlx::query("UPDATE local_users SET last_login = NOW() WHERE id = $1")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(())
}
