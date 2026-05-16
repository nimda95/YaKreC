#!/usr/bin/env bash
# Generate Flutter platform folders the first time we build.
# `flutter create` skips files that already exist, so our pubspec.yaml /
# lib/ aren't touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
cd "$APP"

if [ ! -d android ] || [ ! -d linux ]; then
  echo "==> bootstrapping platform folders"
  flutter create \
    --platforms=android,linux \
    --org=net.kvm \
    --project-name=kvm \
    .
fi

flutter pub get
