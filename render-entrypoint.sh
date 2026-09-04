#!/bin/sh
set -eu

: "${PORT:=10000}"
: "${NULLCLAW_HOME:=/nullclaw-data}"
: "${NULLCLAW_WORKSPACE:=$NULLCLAW_HOME/workspace}"
: "${LLM_BASE_URL:=https://api.openai.com/v1}"
: "${LLM_MODEL:=gpt-4o-mini}"
: "${NULLCLAW_BIND:=0.0.0.0}"

mkdir -p "$NULLCLAW_HOME/workspace"

# Restore the latest archive when a FilesLink download URL is supplied.
if [ -n "${FILESLINK_BACKUP_URL:-}" ]; then
  tmp="$(mktemp)"
  if curl -fsSL --max-time 120 "$FILESLINK_BACKUP_URL" -o "$tmp"; then
    if tar -tzf "$tmp" >/dev/null 2>&1; then
      tar -xzf "$tmp" -C "$NULLCLAW_HOME"
      echo "[render] Restored NullClaw state from FilesLink."
    else
      echo "[render] FilesLink backup is not a valid gzip archive; starting with local state." >&2
    fi
  else
    echo "[render] FilesLink backup unavailable; starting with local state." >&2
  fi
  rm -f "$tmp"
fi

# Inject deployment settings without placing credentials in the repository or
# command line. Preserve any restored config, channels, memory, and workspace.
if [ ! -s "$NULLCLAW_HOME/config.json" ]; then
  printf '%s\n' '{}' > "$NULLCLAW_HOME/config.json"
fi
jq \
  --arg key "${LLM_API_KEY:?Set LLM_API_KEY in Render environment}" \
  --arg base "$LLM_BASE_URL" \
  --arg model "$LLM_MODEL" \
  --argjson port "$PORT" \
  --arg host "$NULLCLAW_BIND" \
  --arg telegram_token "${TELEGRAM_BOT_TOKEN:-}" \
  --arg telegram_user "${TELEGRAM_USER_ID:-}" \
  '.models.providers.openai = {
      api_key: $key, base_url: $base, api_mode: "chat_completions"
    }
   | .agents.defaults.model.primary = ("openai/" + $model)
   | .channels.cli = true
   | .gateway = ((.gateway // {}) + {
       host: $host, port: $port, allow_public_bind: true, require_pairing: true
     })
   | .memory = ((.memory // {}) + {backend: "markdown", auto_save: true})
   | .autonomy = ((.autonomy // {}) + {
       level: "supervised", workspace_only: true, max_actions_per_hour: 30
     })
   | .security = ((.security // {}) + {audit: {enabled: true}})
   | if $telegram_token != "" then
       .channels.telegram = ((.channels.telegram // {}) + {
         accounts: {main: {
           bot_token: $telegram_token,
           allow_from: (if $telegram_user == "" then [] else [$telegram_user] end)
         }}
       })
     else . end' "$NULLCLAW_HOME/config.json" > "$NULLCLAW_HOME/config.json.tmp"
mv "$NULLCLAW_HOME/config.json.tmp" "$NULLCLAW_HOME/config.json"

backup() {
  [ -n "${FILESLINK_UPLOAD_URL:-}" ] || return 0
  archive="$(mktemp --suffix=.tar.gz)"
  tar -czf "$archive" --exclude='*.tmp' -C "$NULLCLAW_HOME" .
  curl -fsS --max-time 180 \
    -X POST \
    -H "X-FilesLink-Upload-Token: ${FILESLINK_UPLOAD_TOKEN:-}" \
    --data-binary "@$archive" \
    "${FILESLINK_UPLOAD_URL}?filename=nullclaw-backup.tar.gz" >/tmp/nullclaw-fileslink-response || true
  rm -f "$archive"
}

# Save before a normal shutdown. Render may terminate abruptly, so use the
# optional Cloudflare ping only to keep the service awake, not as a backup.
trap backup EXIT TERM INT

# Periodic backup process; it is a shell/curl process only and stays lightweight.
if [ -n "${FILESLINK_UPLOAD_URL:-}" ]; then
  (
    while sleep "${FILESLINK_BACKUP_INTERVAL_SECONDS:-900}"; do
      backup
    done
  ) &
fi

echo "[render] Starting NullClaw on ${NULLCLAW_BIND}:${PORT}."
exec /usr/local/bin/nullclaw gateway --port "$PORT" --host "$NULLCLAW_BIND"
