// SPDX-License-Identifier: MIT OR Apache-2.0

//! Local email/password login page.

use dioxus::prelude::*;

use crate::constants::meeting_api_base_url;
use crate::routing::Route;

async fn do_login(email: &str, password: &str) -> Result<(), String> {
    let base_url = meeting_api_base_url().map_err(|e| format!("Config error: {e}"))?;
    let url = format!("{base_url}/auth/login");

    let body = serde_json::json!({
        "email": email,
        "password": password,
    });

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .header("Content-Type", "application/json")
        .fetch_credentials_include()
        .body(body.to_string())
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    if resp.status().as_u16() == 401 {
        return Err("Invalid email or password".into());
    }

    if !resp.status().is_success() {
        return Err(format!("Login failed (HTTP {})", resp.status()));
    }

    Ok(())
}

#[component]
pub fn LoginLocal() -> Element {
    let navigator = use_navigator();
    let mut email = use_signal(String::new);
    let mut password = use_signal(String::new);
    let mut error_msg = use_signal(|| None::<String>);
    let mut loading = use_signal(|| false);

    let on_submit = move |e: Event<FormData>| {
        e.prevent_default();
        let nav = navigator.clone();
        spawn(async move {
            loading.set(true);
            error_msg.set(None);

            let e = email.read().clone();
            let p = password.read().clone();

            match do_login(&e, &p).await {
                Ok(()) => {
                    nav.push(Route::Home {});
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
                p {
                    class: "text-center text-gray-400 mb-6 text-sm",
                    "Sign in to your account"
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
                        label { class: "block text-sm text-gray-400 mb-1", "Email" }
                        input {
                            r#type: "email",
                            class: "w-full px-4 py-2 rounded-lg bg-gray-800 text-foreground border border-gray-700 focus:border-purple-500 focus:outline-none",
                            placeholder: "you@example.com",
                            required: true,
                            value: "{email}",
                            oninput: move |e: Event<FormData>| {
                                email.set(e.value());
                            },
                        }
                    }
                    div { class: "mb-6",
                        label { class: "block text-sm text-gray-400 mb-1", "Password" }
                        input {
                            r#type: "password",
                            class: "w-full px-4 py-2 rounded-lg bg-gray-800 text-foreground border border-gray-700 focus:border-purple-500 focus:outline-none",
                            placeholder: "••••••••",
                            required: true,
                            value: "{password}",
                            oninput: move |e: Event<FormData>| {
                                password.set(e.value());
                            },
                        }
                    }
                    button {
                        r#type: "submit",
                        class: "w-full py-2 rounded-lg bg-purple-600 hover:bg-purple-700 text-white font-semibold transition-colors",
                        disabled: loading(),
                        if loading() { "Signing in..." } else { "Sign in" }
                    }
                }
            }
        }
    }
}
