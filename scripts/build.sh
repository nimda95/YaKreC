#!/usr/bin/env bash
# Single entry point for building the KVM app.
#
# Usage:
#   ./scripts/build.sh --target=apk [--mode=debug|release]
#   ./scripts/build.sh --target=appimage [--mode=debug|release]
#
# Default mode is release. Use --mode=debug for fast dev iteration: skips AOT,
# skips R8, signs with the persistent debug keystore.
#
# The script auto-builds the Docker image and re-execs itself inside the
# container if invoked from the host. Outputs land in build/dist/.
set -euo pipefail

TARGET=""
MODE="release"
IMAGE_TAG="kvm-builder:latest"

usage() {
  cat <<EOF
Usage: $0 --target=<apk|appimage> [--mode=debug|release]

Builds inside a Docker container; nothing is installed on the host.
Outputs land in build/dist/.
EOF
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --target=*) TARGET="${arg#*=}" ;;
    --mode=*)   MODE="${arg#*=}" ;;
    -h|--help)  usage ;;
    *) echo "unknown arg: $arg"; usage ;;
  esac
done

[[ -n "$TARGET" ]] || usage
case "$TARGET" in
  apk|appimage) ;;
  *) echo "invalid target: $TARGET"; usage ;;
esac
case "$MODE" in
  debug|release) ;;
  *) echo "invalid mode: $MODE"; usage ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${KVM_IN_DOCKER:-0}" != "1" ]]; then
  if ! docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    echo "==> building $IMAGE_TAG"
    docker build -t "$IMAGE_TAG" "$ROOT/docker"
  fi
  # Bind-mount pub + gradle caches into a host directory so they survive
  # `docker run --rm`, follow you when the project moves, and can be inspected
  # like any other folder. Override the location with KVM_CACHE_DIR.
  CACHE_DIR="${KVM_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kvm}"
  mkdir -p "$CACHE_DIR/pub" "$CACHE_DIR/gradle" "$CACHE_DIR/keystore" \
           "$CACHE_DIR/android-user" "$CACHE_DIR/android-sdk"

  # Seed the Android SDK cache from the image on first run. Without this the
  # bind-mount would shadow the image's pre-installed cmdline-tools and
  # platform-tools and Gradle would have nothing to invoke. Once seeded, any
  # NDK/build-tools/platform that Gradle pulls in will persist here.
  if [[ ! -d "$CACHE_DIR/android-sdk/cmdline-tools" ]]; then
    echo "==> seeding Android SDK cache from $IMAGE_TAG (first run only)"
    docker run --rm \
      -v "$CACHE_DIR/android-sdk":/dst \
      "$IMAGE_TAG" \
      sh -c 'cp -a /opt/android-sdk-linux/. /dst/'
  fi

  exec docker run --rm \
    -v "$ROOT":/workspace \
    -v "$CACHE_DIR/pub":/root/.pub-cache \
    -v "$CACHE_DIR/gradle":/root/.gradle \
    -v "$CACHE_DIR/keystore":/root/.kvm/keystore \
    -v "$CACHE_DIR/android-user":/root/.android \
    -v "$CACHE_DIR/android-sdk":/opt/android-sdk-linux \
    -e PUB_CACHE=/root/.pub-cache \
    -e GRADLE_USER_HOME=/root/.gradle \
    -e KVM_IN_DOCKER=1 \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e KVM_KEYSTORE_PASS="${KVM_KEYSTORE_PASS:-kvm-release}" \
    -w /workspace \
    "$IMAGE_TAG" \
    ./scripts/build.sh "--target=$TARGET" "--mode=$MODE"
fi

mkdir -p "$ROOT/build/dist"
"$ROOT/scripts/bootstrap.sh"

cd "$ROOT/app"

if [[ "$TARGET" == "apk" && "$MODE" == "release" ]]; then
  KEYSTORE=/root/.kvm/keystore/release.jks
  PASS="${KVM_KEYSTORE_PASS:-kvm-release}"
  if [[ ! -f "$KEYSTORE" ]]; then
    echo "==> generating release keystore at $KEYSTORE (one-time)"
    keytool -genkeypair \
      -keystore "$KEYSTORE" \
      -storetype PKCS12 \
      -alias release \
      -storepass "$PASS" -keypass "$PASS" \
      -keyalg RSA -keysize 2048 -validity 10000 \
      -dname "CN=KVM, OU=KVM, O=KVM, L=Local, S=Local, C=US"
  fi
  cat > "$ROOT/app/android/key.properties" <<EOF
storePassword=$PASS
keyPassword=$PASS
keyAlias=release
storeFile=$KEYSTORE
EOF
elif [[ "$TARGET" == "apk" ]]; then
  # Debug builds use ~/.android/debug.keystore (auto-generated, persistent
  # via the bind-mounted android-user cache). No release signing config.
  rm -f "$ROOT/app/android/key.properties"
fi

case "$TARGET" in
  apk)
    flutter build apk --"$MODE"
    if [[ "$MODE" == "release" ]]; then
      cp build/app/outputs/flutter-apk/app-release.apk "$ROOT/build/dist/kvm.apk"
      echo "==> $ROOT/build/dist/kvm.apk"
    else
      cp build/app/outputs/flutter-apk/app-debug.apk "$ROOT/build/dist/kvm-debug.apk"
      echo "==> $ROOT/build/dist/kvm-debug.apk"
    fi
    ;;

  appimage)
    flutter build linux --"$MODE"
    APPDIR="$ROOT/build/dist/AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr"
    cp -r "build/linux/x64/$MODE/bundle/." "$APPDIR/usr/"

    cat > "$APPDIR/AppRun" <<'SH'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:${LD_LIBRARY_PATH:-}"
exec "$HERE/usr/kvm" "$@"
SH
    chmod +x "$APPDIR/AppRun"

    cat > "$APPDIR/kvm.desktop" <<EOF
[Desktop Entry]
Name=YaKreC
Comment=Yet Another KVM REmote Client
Exec=kvm
Icon=kvm
Type=Application
Categories=Network;
EOF

    # appimagetool needs an icon in the root of the AppDir matching the
    # .desktop file's Icon= line. Reuse the same PNG the GTK runner
    # bundles for gtk_window_set_default_icon_from_file, so the icon
    # shown on the AppImage file matches the one inside the running app.
    cp "$ROOT/app/linux/runner/icon.png" "$APPDIR/kvm.png"

    ARCH=x86_64 appimagetool "$APPDIR" "$ROOT/build/dist/kvm-x86_64.AppImage"
    echo "==> $ROOT/build/dist/kvm-x86_64.AppImage"
    ;;
esac

if [[ -n "${HOST_UID:-}" && -n "${HOST_GID:-}" ]]; then
  chown -R "$HOST_UID:$HOST_GID" "$ROOT/build" "$ROOT/app" 2>/dev/null || true
fi
