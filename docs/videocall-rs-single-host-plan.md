# videocall-rs Single-Host Deployment Plan

## Context

Issue #804 exposes the fundamental problem: the videocall-rs architecture splits WebSocket and WebTransport into separate services connected by NATS, designed for Kubernetes horizontal scaling. On a single bare-metal Ubuntu server this creates three unnecessary layers of complexity:

- **NATS** — pub/sub round-trip for messages that never leave the process
- **Separate WT relay** — a second binary needing its own TLS, ports, and process management
- **LoadBalancer routing** — the entire issue #804 exists because QUIC/UDP can't traverse an HTTP ingress

None of this applies to a single host. The plan: one binary, two listeners, in-process room state.

---

## Target Architecture

```
Single systemd unit: videocall-server
│
├── TCP :443  →  actix-web
│                ├── HTTPS (static WASM assets, API endpoints)
│                ├── WebSocket upgrade (media transport fallback)
│                └── Meeting management REST API
│
├── UDP :443  →  quinn / h3 / h3-webtransport
│                └── QUIC streams (primary media transport)
│
├── Room state  →  Arc<DashMap<RoomId, RoomState>>
│                  ├── Vec<Participant> per room
│                  ├── tokio::broadcast per room (frame fan-out)
│                  └── No NATS, no external broker
│
└── PostgreSQL  →  meetings, users, sessions, JWT auth
```

One TLS cert (Let's Encrypt), one renewal hook, both listeners share it via rustls.

---

## Phase 0 — Fix Current Problems First

**Before any transport work.** These bugs are client-side and transport-independent.

### Audio Echo

Check `dioxus-ui` (or `yew-ui`) getUserMedia constraints. Required:

```rust
// In the media device initialization code
let constraints = MediaStreamConstraints::new();
let audio = MediaTrackConstraints::new();
audio.set_echo_cancellation(true);
audio.set_noise_suppression(true);
audio.set_auto_gain_control(true);
constraints.set_audio(&audio);
```

If the audio goes through a custom WebCodecs pipeline before sending, AEC may be bypassed — the browser's built-in echo cancellation only works on raw MediaStreamTrack. Verify the signal chain.

### Video Quality

Check encoder bitrate defaults in `videocall-client`. The adaptive quality system uses a lowest-common-denominator strategy — on a LAN this should not be the bottleneck. Likely causes:

- Conservative default bitrate (check if it's targeting 300kbps mobile)
- Resolution downscaling before encode
- keyframe interval too aggressive under the diagnostics feedback loop
- VAD threshold misconfigured (see `vadThreshold` in config.js)

**Validate fix:** confirm echo and quality are resolved on current WebSocket deploy before proceeding.

---

## Phase 1 — Remove NATS, In-Process Room State

### Goal

Eliminate the NATS dependency. All room coordination happens in-process.

### Shared Room State

```rust
use dashmap::DashMap;
use tokio::sync::broadcast;

pub struct RoomState {
    pub participants: Vec<Participant>,
    pub tx: broadcast::Sender<Arc<PacketWrapper>>,
}

pub struct Participant {
    pub id: String,
    pub email: String,
    pub transport: TransportKind, // WebSocket | WebTransport
    pub sender: mpsc::Sender<Arc<PacketWrapper>>,
}

pub type Rooms = Arc<DashMap<String, RoomState>>;
```

### Changes

- Extract NATS publish/subscribe from `actix-api` session handlers
- Replace with direct `rooms.get(room_id).tx.send(packet)`
- Each participant's task reads from its `broadcast::Receiver` and writes to its transport
- Original sender filtering: skip `participant.id == packet.sender_id`

### What stays the same

- protobuf `PacketWrapper` / `MediaPacket` — unchanged
- PostgreSQL for meetings, auth — unchanged
- JWT validation — unchanged
- All client code — unchanged

### Feature flag

```rust
#[cfg(feature = "nats")]
mod nats_broker;

#[cfg(not(feature = "nats"))]
mod local_broker;  // in-process DashMap + broadcast
```

Keep NATS as optional for anyone who does want multi-server.

---

## Phase 2 — Add QUIC/WebTransport Listener

### Crate Dependencies

```toml
[dependencies]
quinn = "0.11"
h3 = "0.0.7"
h3-quinn = "0.0.8"
h3-webtransport = "0.0.2"
rustls = { version = "0.23", features = ["ring"] }
```

Pin exact versions — the h3 ecosystem is pre-1.0 and breaks between minors.

### Shared TLS Config

```rust
use rustls::ServerConfig;
use std::sync::Arc;

fn load_tls(cert_path: &str, key_path: &str) -> Arc<ServerConfig> {
    let certs = load_certs(cert_path);
    let key = load_private_key(key_path);

    let mut config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .expect("invalid cert/key");

    // Enable ALPN for both HTTP/1.1 (WebSocket) and H3
    config.alpn_protocols = vec![b"h3".to_vec(), b"h2".to_vec(), b"http/1.1".to_vec()];
    Arc::new(config)
}
```

actix-web uses the same `Arc<ServerConfig>` via actix-tls.
quinn uses it via `quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls_config)))`.

### WebTransport Accept Loop

```rust
async fn run_webtransport(
    bind_addr: SocketAddr,     // 0.0.0.0:443 UDP
    tls_config: Arc<ServerConfig>,
    rooms: Rooms,
) {
    let quic_config = quinn::ServerConfig::with_crypto(/* from rustls config */);
    let endpoint = quinn::Endpoint::server(quic_config, bind_addr).unwrap();

    while let Some(incoming) = endpoint.accept().await {
        let rooms = rooms.clone();
        tokio::spawn(async move {
            let conn = incoming.await?;
            let h3_conn = h3::server::Connection::new(h3_quinn::Connection::new(conn)).await?;
            // Accept WebTransport session
            // Register participant in room
            // Read/write loop using same PacketWrapper as WebSocket path
        });
    }
}
```

### Main Binary

```rust
#[tokio::main]
async fn main() {
    let rooms: Rooms = Arc::new(DashMap::new());
    let tls = load_tls(&cert_path, &key_path);

    let ws_server = run_actix_web("0.0.0.0:443", tls.clone(), rooms.clone());
    let wt_server = run_webtransport("0.0.0.0:443".parse(), tls, rooms);

    // TCP :443 and UDP :443 — same port, different protocols
    tokio::join!(ws_server, wt_server);
}
```

TCP and UDP on port 443 coexist — the OS routes by protocol. No port conflict.

---

## Phase 3 — TLS / Let's Encrypt Automation

### Certificate Setup

```bash
# Install acme.sh
curl https://get.acme.sh | sh

# Issue cert (DNS or HTTP challenge)
acme.sh --issue -d meet.trahe.de --standalone

# Deploy hook — copy certs and signal reload
acme.sh --install-cert -d meet.trahe.de \
  --cert-file /etc/videocall/cert.pem \
  --key-file /etc/videocall/key.pem \
  --fullchain-file /etc/videocall/fullchain.pem \
  --reloadcmd "systemctl reload videocall-server"
```

### Hot Reload

On SIGHUP, the server reloads the cert files and swaps the `Arc<ServerConfig>`:

```rust
use tokio::signal::unix::{signal, SignalKind};

let mut sighup = signal(SignalKind::hangup()).unwrap();
loop {
    sighup.recv().await;
    let new_tls = load_tls(&cert_path, &key_path);
    tls_config_handle.store(new_tls); // arc-swap or similar
}
```

Quinn supports runtime cert rotation via `quinn::ServerConfig` rebuild.

---

## Phase 4 — systemd + Firewall

### systemd Unit

```ini
# /etc/systemd/system/videocall-server.service
[Unit]
Description=videocall-rs single-host server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/videocall-server \
  --cert /etc/videocall/fullchain.pem \
  --key /etc/videocall/key.pem \
  --db-url postgres://videocall:xxx@localhost/videocall \
  --bind-tcp 0.0.0.0:443 \
  --bind-udp 0.0.0.0:443
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
User=videocall
Group=videocall

[Install]
WantedBy=multi-user.target
```

### Firewall

```bash
ufw allow 443/tcp   # HTTPS + WebSocket
ufw allow 443/udp   # QUIC / WebTransport
ufw allow 80/tcp    # ACME HTTP challenge (temporary)
```

No nginx. The single binary terminates TLS for both protocols.

---

## Phase 5 — Frontend Config

```javascript
// config.js — generated or static
window.__APP_CONFIG = Object.freeze({
    loginUrl: "https://meet.trahe.de/login",
    apiUrl: "https://meet.trahe.de",
    websocketUrl: "wss://meet.trahe.de/lobby",
    webTransportUrl: "https://meet.trahe.de",
    webTransportEnabled: true,
    e2eeEnabled: true,
    vadThreshold: 0.02
});
```

Both `websocketUrl` and `webTransportUrl` point to the same host — the client tries WebTransport first, falls back to WebSocket. Same domain, same cert, same port.

---

## What This Eliminates vs. Issue #804

| #804 Kubernetes problem              | Single-host solution          |
|---------------------------------------|-------------------------------|
| Separate LoadBalancer for UDP         | Same port 443, TCP + UDP      |
| Cross-namespace pod routing           | One process, in-memory        |
| NATS for inter-server messaging       | `tokio::broadcast` channels   |
| Named targetPort Kubernetes tricks    | Not applicable                |
| Helm chart complexity                 | One systemd unit              |
| Multiple Docker images                | One binary                    |
| cert-manager + ingress-nginx          | acme.sh + SIGHUP reload       |

---

## Execution Order

1. **Phase 0** — Fix echo + video quality on current deploy (days, client-side only)
2. **Phase 1** — Remove NATS, in-process rooms (1-2 weeks, backend only, test with WebSocket)
3. **Phase 2** — Add QUIC listener (1-2 weeks, biggest risk: h3-webtransport API churn)
4. **Phase 3** — TLS automation (1 day)
5. **Phase 4** — systemd packaging (1 day)
6. **Phase 5** — Frontend config + validation (1 day)

Phases 1+2 are the real work. Everything else is deployment glue.

---

## Open Questions

- **Safari:** Safari supports WebTransport as of 18.2 but behavior may differ from Chrome. Test both paths.
- **h3-webtransport version:** The crate is pre-1.0. Pin and test. The `webtransport.rs` sibling repo from security-union has known-good version pins.
- **E2EE interaction:** The RSA/AES key exchange is transport-agnostic (runs inside PacketWrapper), so it should work unchanged over QUIC streams. Verify.
- **Contribution upstream:** This could be proposed to videocall-rs as a `--single-host` or `--embedded` mode with NATS behind a feature flag. Their K8s users keep their architecture, self-hosters get a single binary.
