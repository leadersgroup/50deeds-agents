#!/usr/bin/env bash
# 50deeds Hermes agent fleet — container bootstrap.
# Idempotent: safe to run on every Railway deploy/restart.
#
# Creates one Hermes PROFILE per business role. Each profile is a fully
# independent agent: own SOUL.md, memory, sessions, skills, credentials,
# Slack identity, and its own s6-supervised gateway.
#
# Single source of truth for the fleet is agents.map.

set -euo pipefail

DATA="${HERMES_HOME:-/opt/data}"
PROFILES="$DATA/profiles"
BIN="$DATA/bin"
SHARE=/usr/local/share/50deeds
HERMES_USER=hermes

log() { echo "[bootstrap] $*"; }

# On Railway the volume is mounted as root and RAILWAY_RUN_UID=0 keeps the
# container root, so s6's /init can chown it. But the supervised gateways run
# as the unprivileged `hermes` user, and the `hermes` CLI shim drops root
# callers to that user too. Anything this script writes with plain shell
# therefore has to be handed back, or the gateways cannot read their own .env.
fix_ownership() {
  [ "$(id -u)" = "0" ] || return 0
  chown -R "$HERMES_USER":"$HERMES_USER" "$DATA" 2>/dev/null || true
}

# Replace-or-append a key in an .env file.
set_env() {
  local file="$1" key="$2" val="$3" tmp
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" 2>/dev/null > "$tmp" || true
  echo "${key}=${val}" >> "$tmp"
  mv "$tmp" "$file"; chmod 600 "$file"
}

mkdir -p "$BIN"

# --- 1. Shared tooling onto the volume (refreshed every deploy) ------------
install -m 0755 "$SHARE/dispatch"    "$BIN/dispatch"
install -m 0755 "$SHARE/sync-staff"  "$BIN/sync-staff"
install -m 0644 "$SHARE/agents.map"  "$BIN/agents.map"

# The roster is seeded once, then the copy on the volume is authoritative so
# you can add or offboard staff over `railway ssh` without a redeploy.
[ -f "$DATA/staff.csv" ] || install -m 0600 "$SHARE/staff.csv" "$DATA/staff.csv"

# --- 2. Per-profile creation and config ------------------------------------
AGENTS=()
while IFS=: read -r name port chan; do
  case "${name:-}" in ''|\#*) continue ;; esac
  AGENTS+=("$name")
  dir="$PROFILES/$name"

  if [ ! -d "$dir" ]; then
    log "creating profile $name"
    hermes profile create "$name" || log "profile create $name returned nonzero"
  fi
  mkdir -p "$dir"
  envfile="$dir/.env"; touch "$envfile"; chmod 600 "$envfile"

  # Per-profile API key for the loopback API server. Generated once.
  keyfile="$dir/.api_key"
  [ -s "$keyfile" ] || { openssl rand -hex 32 > "$keyfile"; chmod 600 "$keyfile"; }

  # API_SERVER_* are env vars, NOT config.yaml keys, and MUST live in the
  # profile's own .env. Setting API_SERVER_PORT as a Railway service variable
  # would force every profile onto one port and they would collide.
  set_env "$envfile" API_SERVER_ENABLED true
  set_env "$envfile" API_SERVER_HOST 127.0.0.1
  set_env "$envfile" API_SERVER_PORT "$port"
  set_env "$envfile" API_SERVER_KEY "$(cat "$keyfile")"

  # Model provider key from the Railway service variables.
  for var in ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY; do
    val="${!var:-}"
    [ -n "$val" ] && set_env "$envfile" "$var" "$val"
  done

  # Slack identity. One Slack app per agent; put its two tokens in Railway as
  # SLACK_BOT_TOKEN_<AGENT> / SLACK_APP_TOKEN_<AGENT>, e.g. for ops-1:
  #   SLACK_BOT_TOKEN_OPS_1=xoxb-...   SLACK_APP_TOKEN_OPS_1=xapp-...
  suffix="$(echo "$name" | tr 'a-z-' 'A-Z_')"
  bot="SLACK_BOT_TOKEN_$suffix"; app="SLACK_APP_TOKEN_$suffix"
  if [ -n "${!bot:-}" ] && [ -n "${!app:-}" ]; then
    set_env "$envfile" SLACK_BOT_TOKEN "${!bot}"
    set_env "$envfile" SLACK_APP_TOKEN "${!app}"
    set_env "$envfile" SLACK_ENABLED true
  else
    log "no Slack tokens for $name (set $bot and $app in Railway)"
  fi

  # SOUL.md = persona and standing instructions. Seeded once; the copy on the
  # volume then wins, so personas are editable live.
  src="$SHARE/souls/${name%%-*}.md"; [ -f "$src" ] || src="$SHARE/souls/ops.md"
  [ -f "$dir/SOUL.md" ] || { sed "s/{{AGENT_NAME}}/$name/g" "$src" > "$dir/SOUL.md"; log "seeded SOUL.md for $name"; }

  # Circuit breaker — off by default, wrong for an unattended gateway.
  cfg="$dir/config.yaml"
  if [ -f "$cfg" ] && ! grep -q 'tool_loop_guardrails' "$cfg"; then
    cat >> "$cfg" <<'YAML'

tool_loop_guardrails:
  hard_stop_enabled: true
  hard_stop_after:
    exact_failure: 5
    idempotent_no_progress: 5
YAML
  fi
done < "$BIN/agents.map"

fix_ownership

# --- 3. Apply the staff roster to every agent's Slack allowlist ------------
"$BIN/sync-staff" || log "sync-staff reported problems — check the roster"
fix_ownership

# --- 4. Start the gateways; park the unused default profile ----------------
for name in "${AGENTS[@]}"; do
  hermes -p "$name" gateway start || log "gateway start $name failed — see logs/gateways/$name/current"
done
hermes gateway stop >/dev/null 2>&1 || true

log "fleet up: ${AGENTS[*]}"

# s6 supervises the gateways; this process only has to stay alive so the
# container does not exit.
exec sleep infinity
