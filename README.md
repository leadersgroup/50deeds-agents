# 50deeds agent fleet — Hermes on Railway

One Railway service. One volume. Four independent agents.

## The architectural decision that drives everything

You do not want eight containers. Hermes has a first-class **profile** system,
and inside the official Docker image each profile gets its own s6-supervised
gateway — so one container runs N fully isolated agents, each with its own
`SOUL.md`, memory, sessions, skills, credentials, and API port. Nous
explicitly recommends one container hosting many profiles over one container
per profile: one image, one venv, per-profile crash restart, one backup.

That also happens to be the only shape that fits Railway cleanly, because a
Railway service can mount exactly one volume, and all Hermes state lives on
`/opt/data`.

The second decision: **department agents are profiles, not subagents.**
Hermes' `delegate_task` spawns ephemeral children with zero memory, no Slack
presence, and no persona — fine for parallel research, useless as "the sales
agent your rep talks to every day." Your COO agent reaches its siblings over
their loopback API servers instead, so a dispatched task lands in the same
persistent agent your staff is talking to.

```
Railway service "hermes"  ──  volume at /opt/data
│
├─ profile coo         :8642   ← you, via Slack + dashboard
├─ profile ceo         :8711
├─ profile ops-1       :8651   ← deed processor
├─ profile ops-2       :8652   ← deed processor
└─ dashboard           :9119   ← the one publicly exposed port
```

COO → sibling dispatch runs over `127.0.0.1`. Nothing but the authenticated
dashboard is reachable from the internet.

## Deploy

1. Push this directory to a GitHub repo.
2. Railway → New Project → Deploy from GitHub repo. It builds the Dockerfile.
3. **Volume**: add one, mount path `/opt/data`. Do this before the first
   successful boot, or the setup wizard's output lands on ephemeral disk.
4. **Start command**: `hermes-bootstrap`
5. **Replicas: 1.** Non-negotiable — two gateways writing the same data
   directory corrupts sessions and memory stores.
6. **Service variables**:

   | Variable | Value |
   |---|---|
   | `ANTHROPIC_API_KEY` | your key (or `OPENROUTER_API_KEY`) |
   | `HERMES_DASHBOARD` | `1` |
   | `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | pick one |
   | `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | long random string |
   | `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | `openssl rand -hex 32` — keeps sessions alive across restarts |
   | `RAILWAY_RUN_UID` | `0` — s6's `/init` must start as root to chown the volume, then it drops to the `hermes` user itself |

   **Never set `API_SERVER_PORT` here.** Railway variables are
   container-wide; a global value forces every profile onto one port and they
   collide. The bootstrap writes it into each profile's own `.env`.

7. **Networking**: generate a domain, target port `9119`. Leave 8642+ unexposed.
8. **Resources**: budget ~500 MB per running gateway. Four agents → 4 GB and
   2 vCPU is a sane starting point. Volume: start at 10 GB.

First deploy creates all four profiles, generates a per-profile API key,
seeds the personas, and starts the gateways.

## Then wire up the humans

Each agent needs **its own Slack app**, so a processor DMs `@50deeds Ops 1`
and a staff member DMs the appropriate profile. Do this once per agent.

### Per-agent Slack checklist

For each agent in `agents.map`:

1. `railway ssh` then `hermes -p <agent> slack manifest --agent-view --write`
   — writes an app manifest tailored to that profile.
2. api.slack.com/apps → **Create New App → From a manifest** → paste it.
   Name it so staff can tell them apart: `50deeds Ops 1`, `50deeds Sales`.
3. Enable **Socket Mode**, generate an App-Level Token (`xapp-`) with
   `connections:write`.
4. Install to workspace, copy the Bot User OAuth Token (`xoxb-`).
5. In Railway service variables, add both, suffixed with the agent name
   uppercased and hyphens as underscores:

   ```
   SLACK_BOT_TOKEN_OPS_1=xoxb-...
   SLACK_APP_TOKEN_OPS_1=xapp-...
   SLACK_BOT_TOKEN_SALES=xoxb-...
   SLACK_APP_TOKEN_SALES=xapp-...
   ```

   The bootstrap picks these up by name and writes them into the right
   profile's `.env`.
6. Invite the bot to any channel it should see: `/invite @50deeds Ops 1`.
   It ignores channels it has not been invited to. DMs need no invite.

Redeploy after adding tokens. Agents without tokens still run — they just
have no Slack presence yet, so you can roll out one department at a time.

### Mapping agents to real staff

`staff.csv` is the roster and the access control list. Hermes denies all
Slack messages by default when nobody is allowlisted, so a person who is not
on a row for an agent simply gets no answer from it.

```
# slack_member_id,name,agent
U04AB1CD2EF,Eric,coo
U04XY9ZW8QR,Dana,ops-1
U04XY9ZW8QR,Dana,ops-2          # same person, two agents = two rows
U04LM3NP4ST,Priya,sales
```

Get a Member ID: click the person in Slack → View full profile → ⋮ → Copy
member ID.

Apply it:

```bash
railway ssh
vi /opt/data/staff.csv
/opt/data/bin/sync-staff --dry-run   # preview the diff
/opt/data/bin/sync-staff             # write + restart only changed agents
/opt/data/bin/sync-staff --show      # who can reach what, right now
```

The roster on the volume is authoritative after first boot, so onboarding
and offboarding are a file edit and one command — no redeploy. Keep the
repo copy updated too, or a fresh volume will come up with stale access.

### How to decide the mapping

- **One agent per person is wrong for ops.** An agent per *processor*
  (`ops-1`, `ops-2`, `ops-3`) means each one accumulates memory about that
  processor's counties and matters. If you'd rather have shared ops
  knowledge, collapse to a single `ops` agent and put all processors on it —
  the tradeoff is a memory that reflects the team, not the person.
- **The COO row is the sensitive one.** That agent can dispatch to every
  other agent, so anyone on it can drive the whole fleet. Keep it to you.
- **Reviewing attorney gets rows on every ops agent**, so escalations can be
  picked up in the same thread the processor was working in.
- **Offboarding is a roster edit, not a Slack deactivation.** The allowlist
  is what the gateway actually checks.

## Using the COO agent

From Slack, talk to the COO normally. It runs `/opt/data/bin/dispatch` via its
terminal tool:

```bash
dispatch --list
dispatch ops-1 "Check the routing requirements for this order"
dispatch --async ops-2 "Review the recording package"
dispatch --status ops-2 run_abc123
```

Dispatches thread under a durable `coo-dispatch` conversation per agent, so
the receiving department remembers the last thing you asked it.

## Adding an agent

Add one line to `agents.map` (`name:port:` — pick an unused port), add a
persona at `souls/<name>.md` if it isn't a variant of an existing role, add
its Slack tokens as Railway variables, add its staff rows to `staff.csv`,
redeploy. The bootstrap is idempotent; existing profiles are untouched.

## Things that will bite you

- **The API server grants full terminal access to that agent.** The keys are
  generated per profile and stored at `/opt/data/profiles/<name>/.api_key`
  with mode 600, and the servers bind `127.0.0.1` only. Keep it that way — an
  exposed Hermes API server and an unauthenticated dashboard were the entry
  point for the June 2026 campaign that had agents planting SSH backdoors.
- **Client PII persists.** Every deed conversation lands in that profile's
  memory on the volume. Decide deliberately what ops agents are allowed to
  retain, and back the volume up somewhere you control.
- **Tool loop guardrails are off by default** and the bootstrap turns them on.
  An unattended gateway with no circuit breaker can burn tokens against a
  failing tool indefinitely.
- **No agent should send externally without a human.** Every persona here
  says draft-then-ask. That constraint is doing real work — an ops agent that
  can file with a county, or a sales agent that can email an attorney, is a
  malpractice surface, not a productivity feature. Loosen it deliberately,
  one capability at a time, after you have watched the logs for a few weeks.
- **Attorney review still gates everything client-facing.** None of these
  agents produce legal advice; they produce internal work product.
- **An empty allowlist fails closed, a wrong one fails open.** Run
  `sync-staff --show` after every roster change and actually read it. A
  typo'd Member ID silently locks someone out; a stray row on `coo` hands
  someone the whole fleet.
- **Model cost is the real bill, not Railway.** Consider routing ops and
  support to a cheaper model in each profile's `config.yaml` and reserving
  the strong model for the COO and drafting work.
