// SPDX-License-Identifier: MIT OR Apache-2.0

//! Account activation page — invited users set their password here.

use dioxus::prelude::*;

use crate::constants::meeting_api_base_url;
use crate::routing::Route;

async fn do_activate(token: &str, password: &str) -> Result<(), String> {
    let base_url = meeting_api_base_url().map_err(|e| format!("Config error: {e}"))?;
    let url = format!("{base_url}/auth/activate");

    let body = serde_json::json!({
        "invite_token": token,
        "password": password,
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .header("Content-Type", "application/json")
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    if resp.status().as_u16() == 404 {
        return Err("Invalid or expired invite token".into());
    }
    if resp.status().as_u16() == 400 {
        return Err("Password must be at least 8 characters".into());
    }
    if !resp.status().is_success() {
        return Err(format!("Activation failed (HTTP {})", resp.status()));
    }

    Ok(())
}

#[component]
pub fn Activate(token: String) -> Element {
    let navigator = use_navigator();
    let mut password = use_signal(String::new);
    let mut password_confirm = use_signal(String::new);
    let mut error_msg = use_signal(|| None::<String>);
    let mut success = use_signal(|| false);
    let mut loading = use_signal(|| false);

    let token_clone = token.clone();

    let on_submit = move |e: Event<FormData>| {
        e.prevent_default();
        let tok = token_clone.clone();
        spawn(async move {
            loading.set(true);
            error_msg.set(None);

            let pw = password.read().clone();
            let pw_confirm = password_confirm.read().clone();

            if pw != pw_confirm {
                error_msg.set(Some("Passwords do not match".into()));
                loading.set(false);
                return;
            }

            if pw.len() < 8 {
                error_msg.set(Some("Password must be at least 8 characters".into()));
                loading.set(false);
                return;
            }

            match do_activate(&tok, &pw).await {
                Ok(()) => {
                    success.set(true);
                }
                Err(msg) => {
                    error_msg.set(Some(msg));
                }
            }
            loading.set(false);
        });
    };

    rsx! {
        div {
            class: "flex items-center justify-center min-h-screen bg-background",
            div {
                class: "w-full max-w-sm p-8 rounded-2xl bg-gray-900 shadow-xl",
                h1 {
                    class: "text-2xl font-bold text-center text-foreground mb-6",
                    "videocall.rs"
                }

                if success() {
                    div {
                        class: "text-center",
                        div {
                            class: "mb-4 p-3 rounded bg-green-900/50 text-green-300 text-sm",
                            "Account activated successfully!"
                        }
                        p {
                            class: "text-gray-400 mb-6 text-sm",
                            "You can now sign in with your email and password."
                        }
                        button {
                            class: "w-full py-2 rounded-lg bg-purple-600 hover:bg-purple-700 text-white font-semibold transition-colors",
                            onclick: move |_| { navigator.push(Route::LoginLocal {}); },
                            "Go to Sign In"
                        }
                    }
                } else {
                    p {
                        class: "text-center text-gray-400 mb-6 text-sm",
                        "Set your password to activate your account"
                    }

                    if let Some(err) = error_msg() {
                        div {
                            class: "mb-4 p-3 rounded bg-red-900/50 text-red-300 text-sm",
                            "{err}"
                        }
                    }

                    form {
                        onsubmit: on_submit,
                        div { class: "mb-4",
                            label { class: "block text-sm text-gray-400 mb-1", "Password" }
                            input {
                                r#type: "password",
                                class: "w-full px-4 py-2 rounded-lg bg-gray-800 text-foreground border border-gray-700 focus:border-purple-500 focus:outline-none",
                                placeholder: "At least 8 characters",
                                required: true,
                                value: "{password}",
                                oninput: move |e: Event<FormData>| {
                                    password.set(e.value());
                                },
                            }
                        }
                        div { class: "mb-6",
                            label { class: "block text-sm text-gray-400 mb-1", "Confirm Password" }
                            input {
                                r#type: "password",
                                class: "w-full px-4 py-2 rounded-lg bg-gray-800 text-foreground border border-gray-700 focus:border-purple-500 focus:outline-none",
                                placeholder: "Repeat password",
                                required: true,
                                value: "{password_confirm}",
                                oninput: move |e: Event<FormData>| {
                                    password_confirm.set(e.value());
                                },
                            }
                        }
                        button {
                            r#type: "submit",
                            class: "w-full py-2 rounded-lg bg-purple-600 hover:bg-purple-700 text-white font-semibold transition-colors",
                            disabled: loading(),
                            if loading() { "Activating..." } else { "Set Password & Activate" }
                        }
                    }
                }
            }
        }
    }
}
