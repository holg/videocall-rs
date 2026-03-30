#!/bin/bash
# Cross-compilation script for videocall-rs meeting-api on macOS
# Builds the backend binary for Linux x86_64 with SQLite support

set -e

HOST_UNAME=$(uname)
TARGET_TRIPLE="${1:-x86_64-unknown-linux-gnu}"

check_target() {
    local target="$1"
    if ! rustup target list | grep -q "^$target (installed)"; then
        echo "Target $target not installed. Installing..."
        rustup target add "$target"
    else
        echo "Target $target is already installed."
    fi
}

echo "Building meeting-api for target: $TARGET_TRIPLE on host: $HOST_UNAME"

if [[ "$HOST_UNAME" == "Darwin" ]]; then
    case "$TARGET_TRIPLE" in
        x86_64-unknown-linux-gnu)
            if ! command -v x86_64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
                echo "Error: x86_64-unknown-linux-gnu-gcc not found in PATH!" >&2
                echo "Please install with:" >&2
                echo "  brew tap messense/macos-cross-toolchains" >&2
                echo "  brew install x86_64-unknown-linux-gnu" >&2
                exit 1
            fi

            export SCCACHE_DISABLE="1"
            export RUSTC_WRAPPER=""

            export CC_x86_64_unknown_linux_gnu="x86_64-unknown-linux-gnu-gcc"
            export AR_x86_64_unknown_linux_gnu="x86_64-unknown-linux-gnu-ar"
            export CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="x86_64-unknown-linux-gnu-gcc"

            unset CC
            unset MACOSX_DEPLOYMENT_TARGET
            export CFLAGS_x86_64_unknown_linux_gnu=""
            export CXXFLAGS_x86_64_unknown_linux_gnu=""

            # OpenSSL for cross-compilation (needed by actix-api/native-tls)
            LINUX_OPENSSL_SYSROOT="$HOME/opt/openssl_for_cross"
            if [ -d "$LINUX_OPENSSL_SYSROOT/lib" ]; then
                export OPENSSL_DIR="$LINUX_OPENSSL_SYSROOT"
                export OPENSSL_STATIC=1
                export PKG_CONFIG_ALLOW_CROSS=1
            fi

            export RUSTFLAGS="-C opt-level=3 -C strip=symbols"
            ;;

        aarch64-unknown-linux-gnu)
            if ! command -v aarch64-unknown-linux-gnu-gcc >/dev/null 2>&1; then
                echo "Error: aarch64-unknown-linux-gnu-gcc not found in PATH!" >&2
                echo "Please install with:" >&2
                echo "  brew tap messense/macos-cross-toolchains" >&2
                echo "  brew install aarch64-unknown-linux-gnu" >&2
                exit 1
            fi

            export SCCACHE_DISABLE="1"
            export RUSTC_WRAPPER=""

            export CC_aarch64_unknown_linux_gnu="aarch64-unknown-linux-gnu-gcc"
            export AR_aarch64_unknown_linux_gnu="aarch64-unknown-linux-gnu-ar"
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="aarch64-unknown-linux-gnu-gcc"

            unset CC
            unset MACOSX_DEPLOYMENT_TARGET
            export CFLAGS_aarch64_unknown_linux_gnu=""
            export CXXFLAGS_aarch64_unknown_linux_gnu=""

            export RUSTFLAGS="-C opt-level=3 -C strip=symbols"
            ;;

        *)
            echo "Error: Unsupported target: $TARGET_TRIPLE" >&2
            echo "Supported targets on macOS:" >&2
            echo "  - x86_64-unknown-linux-gnu" >&2
            echo "  - aarch64-unknown-linux-gnu" >&2
            exit 1
            ;;
    esac
else
    echo "Running on $HOST_UNAME — no cross-compilation setup needed."
fi

check_target "$TARGET_TRIPLE"

echo "Building meeting-api (sqlite) for $TARGET_TRIPLE..."
cargo build \
    --release \
    --target "$TARGET_TRIPLE" \
    -p meeting-api \
    --no-default-features \
    --features sqlite

BINARY_PATH="target/$TARGET_TRIPLE/release/meeting-api"
if [ -f "$BINARY_PATH" ]; then
    echo "✓ meeting-api built: $BINARY_PATH ($(du -h "$BINARY_PATH" | cut -f1))"
else
    echo "✗ meeting-api build failed"
    exit 1
fi

echo "Building websocket_server for $TARGET_TRIPLE..."
cargo build \
    --release \
    --target "$TARGET_TRIPLE" \
    --bin websocket_server

BINARY_PATH="target/$TARGET_TRIPLE/release/websocket_server"
if [ -f "$BINARY_PATH" ]; then
    echo "✓ websocket_server built: $BINARY_PATH ($(du -h "$BINARY_PATH" | cut -f1))"
else
    echo "✗ websocket_server build failed"
    exit 1
fi
