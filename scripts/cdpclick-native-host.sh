#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
exec "$script_directory/../MacOS/auto-click-cdp-popup" --native-messaging-host
