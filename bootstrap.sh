#!/usr/bin/env bash
# 50deeds Hermes agent fleet — container bootstrap.
# Idempotent: safe to run on every Railway deploy/restart.
#
# Creates one Hermes PROFILE per business role. Each profile is a fully
# independent agent: own SOUL.md, memory, sessions, skills, credentials,
# and Slack identity.
#
# Since Hermes v0.22 exactly ONE gateway process per host serves every
# profile ("multiplexing"). It is launched from the default profile (whose
# home is $HERMES_HOME itself) and picks up each profile under profiles/ with
# that profile's own .env, config.yaml, bot tokens and allowlist. Per-profile
# `hermes -p <name> gateway run` is refused by Hermes itself.
#
# Escape hatch: set HERMES_LEGACY_STANDALONE=1 in Railway to go back to one
# gateway per profile (gateway.standalone: true). That is a temporary shim
# upstream and will be removed; use it only to roll back.
#
# Single source of truth for the fleet is agents.map.

set -euo pipefail

DATA="${HERMES_HOME:-/opt/data}"
PROFILES="$DATA/profiles"
BIN="$DATA/bin"
SHARE=/usr/local/share/50deeds
HERMES_USER=hermes
PY=/opt/hermes/.venv/bin/python

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

# Drop a key from an .env file.
unset_env() {
  local file="$1" key="$2" tmp
  grep -q "^${key}=" "$file" 2>/dev/null || return 0
  tmp="$(mktemp)"
  grep -v "^${key}=" "$file" > "$tmp" || true
  mv "$tmp" "$file"; chmod 600 "$file"
}

LEGACY="${HERMES_LEGACY_STANDALONE:-0}"
API_PORT="${HERMES_API_PORT:-8642}"

# config.yaml edits shared by the host (default) profile and every named one.
# Edited as YAML rather than appended, so we never create a duplicate key
# alongside the sentinels that ship on a fresh install.
#   configure_yaml <config.yaml> <role: host|named> <model>
configure_yaml() {
  "$PY" - "$1" "$2" "${HERMES_MODEL_PROVIDER:-anthropic}" "$3" "${HERMES_EMAIL:-0}" "$LEGACY" <<'PYEOF'
import pathlib, sys, yaml

path, role, provider, model = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
email_on, legacy = sys.argv[5] == "1", sys.argv[6] == "1"
try:
    data = yaml.safe_load(path.read_text()) or {} if path.exists() else {}
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}

changed = False

# Unattended gateways need a circuit breaker; the default is off, which is
# only reasonable for an interactive session a human is watching.
if "tool_loop_guardrails" not in data:
    data["tool_loop_guardrails"] = {
        "hard_stop_enabled": True,
        "hard_stop_after": {"exact_failure": 5, "idempotent_no_progress": 5},
    }
    changed = True

# Gateway topology. Host profile: pin multiplexing on. Named profiles: must
# NOT be standalone, or the host skips them and their bots stay silent.
gw = data.get("gateway")
gw = gw if isinstance(gw, dict) else {}
before = dict(gw)
if role == "host":
    gw.pop("standalone", None)          # ignored on default anyway
    if legacy:
        gw.pop("multiplex_profiles", None)
    else:
        gw["multiplex_profiles"] = True
else:
    if legacy:
        gw["standalone"] = True
    else:
        gw.pop("standalone", None)
if gw != before:
    if gw:
        data["gateway"] = gw
    else:
        data.pop("gateway", None)
    changed = True
    print(f"[bootstrap] gateway topology {before} -> {gw} in {path}")

# Keep config.yaml in step with the EMAIL_* parking. Only an existing
# platforms.email block is touched; one is never created.
platforms = data.get("platforms")
email_cfg = platforms.get("email") if isinstance(platforms, dict) else None
if isinstance(email_cfg, dict) and "enabled" in email_cfg and bool(email_cfg["enabled"]) != email_on:
    email_cfg["enabled"] = email_on
    changed = True
    print(f"[bootstrap] platforms.email.enabled={email_on} -> {path}")

# Only seed a model if one was requested and none is set. Never clobber a
# choice made later in the dashboard.
current = data.get("model")
current = current if isinstance(current, dict) else {}
if model and not current.get("default"):
    current["provider"] = provider
    current["default"] = model
    data["model"] = current
    changed = True
    print(f"[bootstrap] model {provider}/{model} -> {path}")

if changed:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data, sort_keys=False))
PYEOF
}

# Railway blocks outbound SMTP (ports 25/465/587/2525) below the Pro plan.
# The email adapter's SMTP connect is a blocking call: while it waits out its
# timeout the gateway's event loop is frozen, so Slack and the API server
# miss their own 30s connect window at startup and Socket Mode drops every
# few minutes afterwards. Unless HERMES_EMAIL=1 is set in Railway (i.e. the
# workspace is on Pro and SMTP actually works), park any EMAIL_* settings the
# dashboard wrote. Nothing is deleted: they move to .env.email-parked and
# come back when HERMES_EMAIL=1.
#   park_email <profile dir> <label>
park_email() {
  local dir="$1" label="$2" envfile="$1/.env" parked="$1/.env.email-parked" tmp
  if [ "${HERMES_EMAIL:-0}" = "1" ]; then
    if [ -s "$parked" ] && ! grep -q '^EMAIL_' "$envfile"; then
      cat "$parked" >> "$envfile"; rm -f "$parked"
      log "restored EMAIL_* settings for $label (HERMES_EMAIL=1)"
    fi
  elif grep -q '^EMAIL_' "$envfile"; then
    grep '^EMAIL_' "$envfile" > "$parked"; chmod 600 "$parked"
    tmp="$(mktemp)"; grep -v '^EMAIL_' "$envfile" > "$tmp" || true
    mv "$tmp" "$envfile"; chmod 600 "$envfile"
    log "email adapter disabled for $label (SMTP is blocked on this plan; settings parked in .env.email-parked, set HERMES_EMAIL=1 to restore)"
  fi
}

# A freshly mounted Railway volume arrives root-owned. Hand it to the hermes
# user BEFORE anything else, because `hermes profile create` drops to that
# user and cannot mkdir under a root-owned /opt/data.
mkdir -p "$BIN" "$PROFILES"
fix_ownership

# --- 1. Shared tooling onto the volume (refreshed every deploy) ------------
install -m 0755 "$SHARE/dispatch"    "$BIN/dispatch"
install -m 0755 "$SHARE/sync-staff"  "$BIN/sync-staff"
install -m 0644 "$SHARE/agents.map"  "$BIN/agents.map"

# The repo is the single source of truth for the roster. Railway gives no
# shell into the running container, so a volume-resident copy could never be
# edited — it would freeze at whatever the first boot wrote. Refresh it from
# the image on every deploy: roster changes go through git, which also gives
# you a version history of who had access to which agent.
install -m 0600 "$SHARE/staff.csv" "$DATA/staff.csv"

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

  # API server. Under multiplexing the host profile owns the ONE listener
  # (127.0.0.1:$API_PORT) and serves this profile at /p/<name>/v1/...,
  # authenticated by this profile's own API_SERVER_KEY. A named profile must
  # not enable api_server itself. The port column in agents.map is only used
  # by the legacy one-gateway-per-profile mode.
  set_env "$envfile" API_SERVER_KEY "$(cat "$keyfile")"
  if [ "$LEGACY" = "1" ]; then
    set_env "$envfile" API_SERVER_ENABLED true
    set_env "$envfile" API_SERVER_HOST 127.0.0.1
    set_env "$envfile" API_SERVER_PORT "$port"
  else
    unset_env "$envfile" API_SERVER_ENABLED
    unset_env "$envfile" API_SERVER_HOST
    unset_env "$envfile" API_SERVER_PORT
  fi

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
    # Tokens may also have been entered in the dashboard, in which case they
    # already sit in this profile's .env and the host gateway will use them.
    if grep -q '^SLACK_BOT_TOKEN=.' "$envfile" && grep -q '^SLACK_APP_TOKEN=.' "$envfile"; then
      log "Slack tokens for $name: found in its profile .env (set in the dashboard)"
    else
      log "no Slack tokens for $name (set $bot and $app in Railway, or add them in the dashboard)"
    fi
  fi

  park_email "$dir" "$name"

  # SOUL.md = persona and standing instructions. Seeded once; the copy on the
  # volume then wins, so personas are editable live.
  src="$SHARE/souls/${name%%-*}.md"; [ -f "$src" ] || src="$SHARE/souls/ops.md"
  [ -f "$dir/SOUL.md" ] || { sed "s/{{AGENT_NAME}}/$name/g" "$src" > "$dir/SOUL.md"; log "seeded SOUL.md for $name"; }

  mdl_var="HERMES_MODEL_$suffix"
  configure_yaml "$dir/config.yaml" named "${!mdl_var:-${HERMES_MODEL:-}}"
done < "$BIN/agents.map"

# --- 2b. Host (default) profile: owns the one gateway and the API listener --
# Its home is $DATA itself. It carries no Slack app and no persona of its
# own; it exists to run the gateway that serves the profiles above.
hostenv="$DATA/.env"; touch "$hostenv"; chmod 600 "$hostenv"
hostkey="$DATA/.api_key"
[ -s "$hostkey" ] || { openssl rand -hex 32 > "$hostkey"; chmod 600 "$hostkey"; }
if [ "$LEGACY" = "1" ]; then
  unset_env "$hostenv" API_SERVER_ENABLED
else
  set_env "$hostenv" API_SERVER_ENABLED true
  set_env "$hostenv" API_SERVER_HOST 127.0.0.1
  set_env "$hostenv" API_SERVER_PORT "$API_PORT"
  set_env "$hostenv" API_SERVER_KEY "$(cat "$hostkey")"
fi
for var in ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY; do
  val="${!var:-}"
  [ -n "$val" ] && set_env "$hostenv" "$var" "$val"
done
park_email "$DATA" "default (host)"

# The host's own adapters connect first and claim their tokens. If the default
# profile still carries a Slack app that a named profile also uses (left over
# from before the fleet had profiles), Hermes would park the NAMED profile as
# a duplicate credential and that agent would answer with the wrong persona.
# The named profile wins: park the host's copy.
if [ "$LEGACY" != "1" ]; then
  hosttok="$(grep '^SLACK_BOT_TOKEN=' "$hostenv" | cut -d= -f2- || true)"
  if [ -n "$hosttok" ]; then
    for name in "${AGENTS[@]}"; do
      if [ "$(grep '^SLACK_BOT_TOKEN=' "$PROFILES/$name/.env" | cut -d= -f2- || true)" = "$hosttok" ]; then
        grep '^SLACK_' "$hostenv" > "$DATA/.env.slack-parked"; chmod 600 "$DATA/.env.slack-parked"
        tmp="$(mktemp)"; grep -v '^SLACK_' "$hostenv" > "$tmp" || true
        mv "$tmp" "$hostenv"; chmod 600 "$hostenv"
        log "default profile shared $name's Slack app — parked the default's copy in .env.slack-parked so $name keeps its bot"
        break
      fi
    done
  fi
fi
configure_yaml "$DATA/config.yaml" host "${HERMES_MODEL:-}"

fix_ownership

# --- 2c. Shared Google Workspace sign-in ------------------------------------
# google-access.map: "source:target target ...". The google-workspace skill
# keeps its OAuth files in the profile home. Copy the source's to each target
# so those agents reach Drive as the same Google account. The first time a
# target's own file is replaced it is kept as <file>.pre-share.
install -m 0644 "$SHARE/google-access.map" "$BIN/google-access.map"
while IFS=: read -r gsrc gtargets; do
  case "${gsrc:-}" in ''|\#*) continue ;; esac
  srcdir="$PROFILES/$gsrc"
  if [ ! -s "$srcdir/google_token.json" ]; then
    log "google share: $gsrc has no google_token.json — nothing to copy"
    continue
  fi
  for gt in $gtargets; do
    tdir="$PROFILES/$gt"
    [ -d "$tdir" ] || { log "google share: unknown profile $gt — skipped"; continue; }
    for f in google_token.json google_client_secret.json; do
      [ -s "$srcdir/$f" ] || continue
      if [ -f "$tdir/$f" ] && cmp -s "$srcdir/$f" "$tdir/$f"; then
        continue
      fi
      [ -f "$tdir/$f" ] && [ ! -e "$tdir/$f.pre-share" ] && cp -p "$tdir/$f" "$tdir/$f.pre-share"
      install -m 0600 "$srcdir/$f" "$tdir/$f"
      log "google share: copied $f from $gsrc to $gt"
    done
  done
done < "$BIN/google-access.map"
fix_ownership

# Live check of each profile's Google sign-in: exchange the refresh token and
# ask Drive who we are. Nothing is written back and no secret is printed. The
# deploy log then says plainly whether each agent can reach Drive, and as whom.
"$PY" - "$PROFILES" "${AGENTS[@]}" <<'PYEOF' || true
import hashlib, json, pathlib, sys, urllib.error, urllib.parse, urllib.request
root = pathlib.Path(sys.argv[1])

def call(url, data=None, headers=None):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data else None, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: body = json.loads(e.read() or b"{}")
        except Exception: body = {}
        return e.code, body
    except Exception as e:
        return 0, {"error": type(e).__name__, "error_description": str(e)[:120]}

for n in sys.argv[2:]:
    home = root / n; f = home / "google_token.json"
    if not f.exists():
        print(f"[google] {n}: no google_token.json"); continue
    try:
        t = json.loads(f.read_text())
    except Exception as e:
        print(f"[google] {n}: token unreadable ({type(e).__name__})"); continue
    cid, csec = t.get("client_id"), t.get("client_secret")
    if not (cid and csec):
        try:
            cs = json.loads((home / "google_client_secret.json").read_text())
            cs = cs.get("installed") or cs.get("web") or {}
            cid, csec = cid or cs.get("client_id"), csec or cs.get("client_secret")
        except Exception:
            pass
    scopes = t.get("scopes") or t.get("scope") or []
    if isinstance(scopes, str): scopes = scopes.split()
    short = sorted(x.rsplit("/", 1)[-1] for x in scopes)
    rt = t.get("refresh_token") or ""
    ident = hashlib.sha256(rt.encode()).hexdigest()[:8]
    if not (rt and cid and csec):
        print(f"[google] {n}: sign-in {ident} incomplete (refresh_token={bool(rt)} client_id={bool(cid)} client_secret={bool(csec)}) keys={sorted(t)}")
        continue
    code, body = call(t.get("token_uri") or "https://oauth2.googleapis.com/token",
                      {"grant_type": "refresh_token", "refresh_token": rt, "client_id": cid, "client_secret": csec})
    if code != 200 or "access_token" not in body:
        print(f"[google] {n}: sign-in {ident} REFRESH FAILED http={code} error={body.get('error')} detail={str(body.get('error_description'))[:120]} scopes={short}")
        continue
    code2, who = call("https://www.googleapis.com/drive/v3/about?fields=user(emailAddress)",
                      headers={"Authorization": "Bearer " + body["access_token"]})
    if code2 == 200:
        print(f"[google] {n}: sign-in {ident} OK — Drive reachable as {who.get('user', {}).get('emailAddress')} scopes={short}")
    else:
        err = who.get("error") if isinstance(who.get("error"), dict) else {}
        print(f"[google] {n}: sign-in {ident} refreshed but Drive call failed http={code2} {str(err.get('message') or who)[:160]} granted={body.get('scope')}")
PYEOF

# --- 2d. Integration inventory ----------------------------------------------
# No shell into this container, so print what each profile is wired to on
# every boot: MCP server names, and which Google/OAuth credential files and
# env keys exist. Names only. Values, tokens and args are never printed.
"$PY" - "$DATA" "${AGENTS[@]}" <<'PYEOF' || log "inventory step failed (non-fatal)"
import os, pathlib, re, sys, yaml
data = pathlib.Path(sys.argv[1]); names = sys.argv[2:]
pat = re.compile(r"google|gdrive|drive|gws|oauth|token|credential|client_secret|mcp", re.I)
skip = {"sessions", "logs", "cache", ".cache", "node_modules", ".venv", ".venvs", ".venv-gws", "memories", "checkpoints", "__pycache__", "lazy-packages", "skills", "tmp", ".local", ".config", ".hermes", "wiki"}
for name, home in [("default", data)] + [(n, data / "profiles" / n) for n in names]:
    try:
        cfg = yaml.safe_load((home / "config.yaml").read_text()) or {}
    except Exception as e:
        cfg = {}; print(f"[inventory] {name}: config.yaml unreadable ({type(e).__name__})")
    for key in ("mcp_servers", "mcp"):
        block = cfg.get(key)
        if isinstance(block, dict):
            for srv, spec in block.items():
                spec = spec if isinstance(spec, dict) else {}
                url = str(spec.get("url", ""))
                host = re.sub(r"^(https?://[^/?#]+).*", r"\1", url) if url else ""
                cmd = str(spec.get("command", ""))
                print(f"[inventory] {name}: {key}.{srv} keys={sorted(spec)} url_host={host or '-'} command={cmd or '-'} "
                      f"env_keys={sorted(spec.get('env') or {}) if isinstance(spec.get('env'), dict) else '-'} "
                      f"auth={spec.get('auth', '-') if not isinstance(spec.get('auth'), dict) else sorted(spec['auth'])}")
    for key in ("toolsets", "platform_toolsets", "skills", "plugins"):
        if key in cfg:
            v = cfg[key]
            print(f"[inventory] {name}: {key} = {v if not isinstance(v, dict) else {k: (x if isinstance(x, (list, bool, str, int)) else sorted(x) if isinstance(x, dict) else '...') for k, x in v.items()}}")
    try:
        keys = [l.split("=", 1)[0] for l in (home / ".env").read_text().splitlines() if "=" in l and not l.startswith("#")]
        hits = [k for k in keys if re.search(r"GOOGLE|GDRIVE|DRIVE|GWS|MCP|OAUTH", k)]
        print(f"[inventory] {name}: .env keys matching google/mcp/oauth: {hits or 'none'}")
    except Exception:
        pass
    found = []
    for root, dirs, files in os.walk(home):
        rel = pathlib.Path(root).relative_to(home)
        if name == "default":
            dirs[:] = [d for d in dirs if d != "profiles"]
        dirs[:] = [d for d in dirs if d not in skip]
        if len(rel.parts) >= 4:
            dirs[:] = []
        for x in list(dirs) + files:
            if pat.search(x):
                fp = pathlib.Path(root) / x
                size = fp.stat().st_size if fp.is_file() else "dir"
                found.append(f"{rel / x} ({size})")
    for f in sorted(found)[:60]:
        print(f"[inventory] {name}: file {f}")
PYEOF

# --- 3. Apply the staff roster to every agent's Slack allowlist ------------
"$BIN/sync-staff" --no-restart || log "sync-staff reported problems — check the roster"

# Print the effective access map on every boot. There is no shell into the
# running container on Railway, so the deploy log is the only window into
# what each agent's allowlist actually contains.
"$BIN/sync-staff" --show || true
fix_ownership

# --- 4. Start the gateway and the dashboard ---------------------------------
# Inside the stock image s6-overlay is PID 1. Railway's custom start command
# bypasses the image ENTRYPOINT, so /init never runs and `gateway start`
# falls back to a legacy no-op. So we supervise the processes ourselves.

# Restart-on-exit wrapper. A gateway is a long-lived foreground process; if
# it dies we bring it back rather than losing the fleet silently.
supervise() {
  local label="$1"; shift
  (
    while true; do
      # sed -u: line-buffered. Without it sed block-buffers into the pipe and
      # the Railway deploy log shows gateway output minutes to an hour late.
      "$@" 2>&1 | sed -u "s/^/[$label] /"
      log "$label exited (rc=$?) — restarting in 5s"
      sleep 5
    done
  ) &
}

if [ "$LEGACY" = "1" ]; then
  log "HERMES_LEGACY_STANDALONE=1 — one standalone gateway per profile"
  for name in "${AGENTS[@]}"; do
    supervise "$name" hermes -p "$name" gateway run
    sleep 1
  done
else
  # Fold any leftovers of the old per-profile topology (stale state files,
  # the multiplex flag) onto the host. Idempotent; nothing is running yet, so
  # there is no live secondary gateway to block it. Output goes to the deploy
  # log because that is the only window into this container.
  log "multiplex migration check:"
  timeout 120 hermes -p default gateway migrate --multiplex -y 2>&1 | sed -u 's/^/[migrate] /' \
    || log "gateway migrate returned nonzero — continuing; the host gateway decides at boot"
  fix_ownership
  # -p default is required: the volume has a sticky active profile (coo), so a
  # bare `hermes gateway run` resolves to coo and Hermes refuses it.
  log "starting the host gateway (serves: ${AGENTS[*]})"
  supervise gateway hermes -p default gateway run
fi

if [ "${HERMES_DASHBOARD:-}" = "1" ]; then
  supervise dashboard hermes dashboard \
    --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
    --port "${HERMES_DASHBOARD_PORT:-9119}" \
    --no-open
fi

log "fleet up: ${AGENTS[*]}"

# Stay in the foreground so the container lives as long as its children.
wait
