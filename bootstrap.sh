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

# Chromium sandbox: Hermes only adds --no-sandbox when it detects root or
# Docker. On Railway it sees neither (the agents run as the hermes user and
# there is no /.dockerenv), so Chromium aborts at startup (exit -6). Pin the
# flags here; any other chromium_args set in the dashboard are kept.
browser = data.get("browser")
browser = browser if isinstance(browser, dict) else {}
args = browser.get("chromium_args") or []
if isinstance(args, str):
    args = [x.strip() for x in args.replace("\n", ",").split(",") if x.strip()]
args = [str(x) for x in args]
missing = [f for f in ("--no-sandbox", "--disable-dev-shm-usage") if f not in args]
if missing:
    browser["chromium_args"] = args + missing
    data["browser"] = browser
    changed = True
    print(f"[bootstrap] browser.chromium_args += {missing} -> {path}")

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

# --- 0. Disk guard ----------------------------------------------------------
# The volume is small and there is no shell into this container, so a full
# disk is invisible until every write fails with ENOSPC. This step runs FIRST,
# before anything below writes to the volume (a full disk would otherwise kill
# this script under `set -e` and crash-loop the fleet):
#   1. print where the space is (deploy log is the only window),
#   2. prune things that are safe to lose: oversized/rotated logs, package
#      caches, stale cached downloads, core dumps,
#   3. delete any extra paths named in HERMES_PRUNE_EXTRA (Railway variable,
#      space-separated, relative to $DATA) — the way to remove a specific
#      culprit the report points at, since nobody can `rm` it by hand.
# Nothing here touches sessions, memories, SOUL.md, config or credentials.
# Tunables: HERMES_LOG_MAX_MB (20), HERMES_CACHE_MAX_DAYS (3),
#           HERMES_DISK_WATCH_MIN (15), HERMES_DISK_WARN_PCT (85).

disk_used_pct() { df -P "$DATA" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'; }

disk_report() (
  set +e +o pipefail
  tag="$1"
  df -h "$DATA" 2>/dev/null | sed -u "s/^/[disk] $tag: /"
  echo "[disk] $tag: largest directories (MB):"
  timeout 180 du -x -m --max-depth=4 "$DATA" 2>/dev/null | sort -rn | head -40 \
    | awk '{mb=$1; $1=""; printf "[disk] %7d MB %s\n", mb, $0}'
  echo "[disk] $tag: files over 20 MB:"
  timeout 120 find "$DATA" -xdev -type f -size +20M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null \
    | sort -rn | head -25 \
    | awk -F'\t' '{printf "[disk] %7d MB  %s  %s\n", $1/1048576, $2, $3}'
  exit 0
)

disk_prune() (
  set +e +o pipefail
  max_mb="${HERMES_LOG_MAX_MB:-20}"; days="${HERMES_CACHE_MAX_DAYS:-3}"
  # Never descend into code/package trees: nothing in them is ours to prune.
  skip=( \( -name node_modules -o -name '.venv*' -o -name .venvs -o -name lazy-packages -o -name .git \) -prune -o )

  # Rotated / compressed logs older than 2 days. (rm via -exec, not -delete:
  # -delete turns on -depth, which disables the -prune above.)
  find "$DATA" -xdev "${skip[@]}" -type f \
    \( -name '*.log.[0-9]*' -o -name '*.log.gz' -o -name '*.log.*.gz' -o -name '*.log.old' \) \
    -mtime +2 -print -exec rm -f {} + 2>/dev/null | sed -u 's/^/[disk] removed rotated log /'

  # Live logs over the cap: keep the tail. Staged in /tmp (container disk, not
  # the volume) so this works even when the volume has zero bytes free.
  find "$DATA" -xdev "${skip[@]}" -type f -name '*.log' -size +"${max_mb}"M -print 2>/dev/null \
    | while IFS= read -r f; do
        before=$(stat -c %s "$f" 2>/dev/null || echo 0)
        tmp="$(mktemp /tmp/logtail.XXXXXX)" || continue
        if tail -c 2097152 "$f" > "$tmp" 2>/dev/null && cat "$tmp" > "$f" 2>/dev/null; then
          echo "[disk] truncated $f ($((before / 1048576)) MB -> 2 MB tail)"
        fi
        rm -f "$tmp"
      done

  # Package-manager download caches: re-fetched on demand.
  for rel in .cache/pip .cache/uv .cache/node-gyp .npm/_cacache .npm/_logs; do
    find "$DATA" -xdev -maxdepth 4 -type d -path "*/$rel" -print 2>/dev/null \
      | while IFS= read -r d; do
          mb=$(du -sm "$d" 2>/dev/null | cut -f1)
          rm -rf "$d" && echo "[disk] removed package cache $d (${mb:-?} MB)"
        done
  done

  # Stale files in Hermes download/media caches and scratch dirs.
  find "$DATA" -xdev -maxdepth 4 "${skip[@]}" -type d \
    \( -name cache -o -name image_cache -o -name audio_cache -o -name document_cache -o -name tmp \) -print 2>/dev/null \
    | while IFS= read -r d; do
        # Agents build virtualenvs and --target dirs inside cache/. Deleting
        # their old files one by one would leave a broken environment, so
        # those trees are left alone (the [pyenv] inventory below lists them).
        n=$(find "$d" -xdev \( -type d \( -exec test -e '{}/pyvenv.cfg' \; -o -name pydeps -o -name site-packages -o -name node_modules \) -prune \) \
              -o -type f -mtime +"$days" -print -exec rm -f {} + 2>/dev/null | wc -l)
        [ "$n" -gt 0 ] && echo "[disk] removed $n file(s) older than ${days}d from $d"
      done

  # Core dumps.
  find "$DATA" -xdev "${skip[@]}" -type f \( -name 'core' -o -name 'core.[0-9]*' \) -size +10M -print -exec rm -f {} + 2>/dev/null \
    | sed -u 's/^/[disk] removed core dump /'

  # Operator-named extras. Relative to $DATA only; must resolve inside it.
  root="$(realpath "$DATA")"
  for rel in ${HERMES_PRUNE_EXTRA:-}; do
    case "$rel" in /*|*..*|.|./|profiles|profiles/) echo "[disk] HERMES_PRUNE_EXTRA: refusing '$rel'"; continue ;; esac
    target="$(realpath -m "$root/$rel")"
    case "$target" in
      "$root"/?*) ;;
      *) echo "[disk] HERMES_PRUNE_EXTRA: refusing '$rel' (outside $root)"; continue ;;
    esac
    if [ -e "$target" ]; then
      mb=$(du -sm "$target" 2>/dev/null | cut -f1)
      rm -rf "$target" && echo "[disk] HERMES_PRUNE_EXTRA: removed $rel (${mb:-?} MB)"
    else
      echo "[disk] HERMES_PRUNE_EXTRA: $rel not present (already removed — unset the variable)"
    fi
  done
  exit 0
)

if [ -d "$DATA" ]; then
  disk_report "before prune" || true
  disk_prune || true
  log "disk after prune: $(df -h "$DATA" 2>/dev/null | awk 'NR==2 {print $3" used of "$2" ("$5"), "$4" free"}')"
  pct="$(disk_used_pct || true)"
  if [ "${pct:-0}" -ge 97 ]; then
    log "WARNING: volume still ${pct}% full after pruning. Grow the volume in Railway, or set HERMES_PRUNE_EXTRA to a path from the [disk] report above and redeploy."
  fi
fi

# --- 0b. Python environment inventory ---------------------------------------
# Agents install their own Python packages into ad-hoc virtualenvs on the
# volume. Print what each one holds so the packages can be baked into the
# image instead (names and versions only).
py_inventory() (
  set +e +o pipefail
  for c in python3 python uv pip; do
    w="$(command -v "$c" 2>/dev/null)"; echo "[pyenv] PATH $c -> ${w:-none} $([ -n "$w" ] && "$w" --version 2>&1 | head -1)"
  done
  "$PY" - "$DATA" <<'PYEOF'
import os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
skip = {"node_modules", ".git", "lazy-packages", ".npm", "sessions", "memories", "logs", "skills", "wiki"}
def dists(sp):
    out = []
    for d in sorted(sp.glob("*.dist-info")):
        m = re.match(r"(.+)-([^-]+)\.dist-info$", d.name)
        if m: out.append(f"{m.group(1)}=={m.group(2)}")
    return out
for cur, dirs, files in os.walk(root):
    p = pathlib.Path(cur); depth = len(p.relative_to(root).parts)
    dirs[:] = [d for d in dirs if d not in skip]
    if depth >= 7: dirs[:] = []
    if "pyvenv.cfg" in files:
        dirs[:] = []
        ver = next((l.split("=",1)[1].strip() for l in (p/"pyvenv.cfg").read_text().splitlines() if l.startswith(("version","version_info"))), "?")
        ok = any((p/"bin"/n).exists() for n in ("python", "python3"))
        pk = []
        for sp in p.glob("lib/python*/site-packages"): pk += dists(sp)
        print(f"[pyenv] venv {p} python={ver} interpreter={'ok' if ok else 'MISSING'} packages({len(pk)}): {' '.join(pk)}")
    elif p.name == "pydeps":
        dirs[:] = []
        pk = dists(p)
        print(f"[pyenv] target-dir {p} packages({len(pk)}): {' '.join(pk)}")
    elif p.name in ("scratch",):
        scripts = sorted(f for f in files if f.endswith((".py", ".sh")))[:40]
        if scripts: print(f"[pyenv] scripts in {p}: {' '.join(scripts)}")
PYEOF
  exit 0
)
[ -d "$DATA" ] && { py_inventory || true; }
"$PY" -c "import pymupdf, onnxruntime, docx, googleapiclient, openpyxl; print('[pyenv] preinstalled agent libs import ok (pymupdf', pymupdf.__version__ + ', onnxruntime', onnxruntime.__version__ + ')')" 2>&1 | tail -1 \
  || log "WARNING: preinstalled agent libs failed to import — check requirements-agents.txt"

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

  # Managed note in SOUL.md: which Python libraries are already installed.
  # Without it agents rebuild a virtualenv per task under cache/, which is
  # what filled the volume. Only the block between the markers is rewritten;
  # the rest of the persona (editable live) is left exactly as it is.
  "$PY" - "$dir/SOUL.md" "$SHARE/requirements-agents.txt" <<'PYEOF' || log "could not update the python note in SOUL.md for $name (non-fatal)"
import pathlib, re, sys
soul, req = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
pkgs = [l.split("==")[0].strip() for l in req.read_text().splitlines() if l.strip() and not l.startswith("#")]
start, end = "<!-- 50deeds:python-libs:start -->", "<!-- 50deeds:python-libs:end -->"
block = f"""{start}
## Python libraries already installed

These are preinstalled and importable from the default `python3`. Use them
directly: {", ".join(pkgs)}.

Do not create virtualenvs and do not `pip install` or `uv pip install`
anything onto /opt/data. The disk there is small and filled up from exactly
that. If a task needs a library that is not on this list, say so in your
reply so it can be added to the image.

## Case reviews

For any review, QC or re-check of a 50deeds case, order, deed or signing
package, load the `50deeds-case-review` skill first and follow it. It is the
only case review skill: do not create, follow or patch a separate review
skill. If staff correct a review rule, quote the corrected rule in your reply
so it can be added to that skill.
{end}"""
text = soul.read_text() if soul.exists() else ""
if start in text and end in text:
    new = re.sub(re.escape(start) + r".*?" + re.escape(end), lambda m: block, text, flags=re.S)
else:
    new = text.rstrip("\n") + "\n\n" + block + "\n"
if new != text:
    soul.write_text(new)
    print(f"[bootstrap] python-libs note written to {soul}")
PYEOF

  # 50deeds skills from the repo (hermes-skills/<category>/<skill>/). The repo
  # is the source of truth: each one is replaced whole on every deploy, so an
  # agent's in-place edits don't survive. Other skills are left alone.
  if [ -d "$SHARE/skills" ]; then
    for skill in "$SHARE"/skills/*/*/; do
      [ -f "$skill/SKILL.md" ] || continue
      rel="${skill#"$SHARE"/skills/}"; rel="${rel%/}"
      dest="$dir/skills/$rel"
      rm -rf "$dest"; mkdir -p "$(dirname "$dest")"; cp -R "${skill%/}" "$dest"
    done
  fi

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
# google-access.map: "source:target target ...". See google-share for the
# rules (a live source is copied to its targets; a dead one never is). It
# also prints, per agent, whether Drive is reachable and as which account.
install -m 0644 "$SHARE/google-access.map" "$BIN/google-access.map"
install -m 0755 "$SHARE/google-share"      "$BIN/google-share"
"$PY" "$BIN/google-share" sync || log "google-share reported problems (non-fatal)"
fix_ownership

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

# Re-share as soon as a source agent signs in to Google again, so a fresh
# sign-in on coo reaches the ops agents without a redeploy.
"$PY" "$BIN/google-share" watch &

if [ "${HERMES_DASHBOARD:-}" = "1" ]; then
  supervise dashboard hermes dashboard \
    --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
    --port "${HERMES_DASHBOARD_PORT:-9119}" \
    --no-open
fi

# Disk watch: one usage line every HERMES_DISK_WATCH_MIN minutes, plus the
# full breakdown (and a log/cache prune) once usage crosses the warn line, so
# whatever is growing shows up in the deploy log before the volume is full.
(
  set +e
  every="${HERMES_DISK_WATCH_MIN:-15}"; warn="${HERMES_DISK_WARN_PCT:-85}"
  while sleep "$((every * 60))"; do
    pct="$(disk_used_pct)"
    echo "[disk] watch: $(df -h "$DATA" 2>/dev/null | awk 'NR==2 {print $3" used of "$2" ("$5")"}')"
    if [ "${pct:-0}" -ge "$warn" ]; then
      disk_prune
      disk_report "watch (>= ${warn}%)"
    fi
  done
) &

# Retire agent-written skills that duplicate a repo skill. Matched by the
# frontmatter name or folder name; moved (not deleted) to
# $DATA/retired-skills/<profile>/ and printed once so anything useful in them
# can be folded into the repo skill. Override with HERMES_RETIRE_SKILLS.
"$PY" - "$DATA" ${HERMES_RETIRE_SKILLS:-deed-case-qc-review} <<'PYEOF' || log "skill retirement step failed (non-fatal)"
import pathlib, re, shutil, sys, time
data = pathlib.Path(sys.argv[1]); names = set(sys.argv[2:])
for skill_md in sorted(data.glob("profiles/*/skills/**/SKILL.md")):
    d = skill_md.parent
    if "50deeds" in d.relative_to(data).parts:
        continue                                   # repo-managed, never retired
    try:
        head = skill_md.read_text(errors="replace")
    except OSError:
        continue
    m = re.search(r"^name:\s*['\"]?([^'\"\n]+)", head, re.M)
    name = (m.group(1).strip() if m else "") or d.name
    if name not in names and d.name not in names:
        continue
    profile = d.relative_to(data).parts[1]
    dest = data / "retired-skills" / profile / f"{d.name}-{time.strftime('%Y%m%d-%H%M%S')}"
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"[skills] retiring {d} (name: {name}) -> {dest}")
    for line in head.splitlines()[:400]:
        print(f"[skills] | {line}")
    for extra in sorted(p for p in d.rglob("*") if p.is_file() and p != skill_md):
        print(f"[skills] + file {extra.relative_to(d)} ({extra.stat().st_size} bytes)")
    shutil.move(str(d), str(dest))
PYEOF
fix_ownership

# Browser smoke test, as the user the agents run as, with and without the
# pinned flags, so the deploy log shows whether the browser tool can work.
(
  set +e
  exe="$("$PY" -c 'from hermes_cli.browser_runtime import chromium_executable as c; print(c() or "")' 2>/dev/null)"
  if [ -n "$exe" ] && [ -x "$exe" ]; then
    as_hermes() { if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null; then runuser -u "$HERMES_USER" -- "$@"; else "$@"; fi; }
    # Launched the way Hermes does: headless with a DevTools port, success =
    # Chromium writes DevToolsActivePort. Each variant gets 30s.
    for flags in "--no-sandbox --disable-dev-shm-usage" "--no-sandbox --disable-dev-shm-usage --disable-gpu --no-zygote"; do
      udd="$(mktemp -d /tmp/chromium-smoke.XXXXXX)"; chmod 777 "$udd"
      as_hermes "$exe" --headless=new --remote-debugging-port=0 --user-data-dir="$udd" --no-first-run $flags about:blank >"$udd.log" 2>&1 &
      pid=$!; res="FAILED: no DevTools endpoint within 30s"
      for _ in $(seq 1 60); do
        if [ -s "$udd/DevToolsActivePort" ]; then res=OK; break; fi
        if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; res="FAILED: exited rc=$?"; break; fi
        sleep 0.5
      done
      [ "$res" = OK ] || res="$res; $(grep -v '^\s*#' "$udd.log" | grep -v 'dbus/bus.cc' | grep -m2 -iE 'error|fatal|abort|sandbox|shm|font|gpu' | tr '\n' ' ' | cut -c1-260)"
      pkill -f "user-data-dir=$udd" 2>/dev/null; sleep 0.5; rm -rf "$udd" "$udd.log"
      log "chromium smoke test (flags: $flags): $res"
    done
  else
    log "chromium smoke test skipped: no packaged Chromium found"
  fi
)

log "50deeds skills installed: $(cd "$SHARE/skills" 2>/dev/null && ls -d */*/ 2>/dev/null | sed 's#/$##' | tr '\n' ' ' | sed 's/ $//') -> ${AGENTS[*]}"
log "fleet up: ${AGENTS[*]}"

# Stay in the foreground so the container lives as long as its children.
wait
