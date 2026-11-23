#!/bin/sh
set -eu
# Base64 keeps operator-provided URLs out of JavaScript string syntax.
encoded_url=$(printf '%s' "${WEB_API_BASE_URL:-}" | base64 | tr -d '\n')
api_port=${API_PORT:-6601}
case "$api_port" in ''|*[!0-9]*) echo 'API_PORT 必须为数字' >&2; exit 1 ;; esac
printf 'globalThis.__AI_DETECT_CONFIG__ = {apiBaseUrl: atob("%s"), apiPort: "%s"};\n' "$encoded_url" "$api_port" > /usr/share/nginx/html/app-config.js
