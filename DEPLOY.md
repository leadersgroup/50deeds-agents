# DEPLOY — run these on your machine

`railway.json` sets the builder, start command, and `numReplicas: 1` for you.
Volumes and variables cannot be declared in config-as-code, so those are the
only manual steps.

## 1. Repo

```bash
cd hermes-50deeds
git init && git add -A && git commit -m "50deeds Hermes agent fleet"
gh repo create 50deeds-agents --private --source=. --push
```

## 2. Project

```bash
npm i -g @railway/cli     # or: brew install railway
railway login
railway init              # name it: 50deeds-agents
railway link              # if the project already exists
```

## 3. Volume — do this BEFORE the first deploy

```bash
railway volume add
# select the service, mount path: /opt/data
```

If the service boots without the volume, all agent config and memory lands on
ephemeral disk and disappears on the next deploy.

## 4. Variables

```bash
railway variables \
  --set "ANTHROPIC_API_KEY=sk-ant-..." \
  --set "HERMES_DASHBOARD=1" \
  --set "HERMES_DASHBOARD_BASIC_AUTH_USERNAME=eric" \
  --set "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$(openssl rand -hex 24)" \
  --set "HERMES_DASHBOARD_BASIC_AUTH_SECRET=$(openssl rand -hex 32)" \
  --set "RAILWAY_RUN_UID=0"
```

Write down the generated password — you will not see it again from the CLI.

Do **not** set `API_SERVER_PORT` here. Railway variables are container-wide
and a global value forces every profile onto one port; they will collide.

Slack tokens come later, once the apps exist (see README):

```bash
railway variables \
  --set "SLACK_BOT_TOKEN_OPS_1=xoxb-..." \
  --set "SLACK_APP_TOKEN_OPS_1=xapp-..."
```

## 5. Resources and networking

In the Railway dashboard, on the service:

- **Settings → Resources**: 8 GB RAM, 4 vCPU (≈500 MB per running gateway)
- **Settings → Networking → Generate Domain**, target port `9119`
- Leave 8642 and everything above it unexposed — those are the agents' API
  servers and they grant terminal access

## 6. Deploy

```bash
railway up
railway logs
```

Expect to see `[bootstrap] creating profile coo` … through
`[bootstrap] fleet up: coo ops-1 ops-2 ops-3 sales marketing support-1 support-2`.

## 7. Verify before you invite anyone

```bash
railway ssh
hermes profile list                   # 8 profiles + default
hermes -p coo gateway status
/opt/data/bin/sync-staff --show       # will show 0 staff until you fill the roster
tail -F /opt/data/logs/gateways/coo/current
```

Then open the dashboard domain, log in with the basic-auth credentials, and
send the COO agent a message from the profile switcher. Once that round-trips,
do the Slack apps and the roster.

## Order matters

Volume → variables → deploy → verify → Slack apps → roster → invite staff.
Skipping ahead to Slack before the fleet is proven just adds a second place
for a failure to hide.
