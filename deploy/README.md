# Deploying Vista to hub

Vista runs on `hub.t.internal` from `/opt/vista`, the same shape as relay:
the repo is cloned on the host, `docker-compose.prod.yml` describes the stack,
and `vista-update` pulls and redeploys.

|  | URL |
|---|---|
| Web client | `http://hub.t.internal:5190` |
| API | `http://hub.t.internal:5191` |

Both publish on all interfaces, so they're reachable across the tailnet.

## Updating

```bash
ssh root@hub.t.internal vista-update
```

It fetches, shows what's incoming, rebuilds only the services whose files
changed, restarts those, and waits for `/api/health` before reporting. Run with
nothing new to deploy and it still brings the stack up — which is also how you
recover after a reboot.

## First-time setup

```bash
git clone https://github.com/druths/vista.git /opt/vista
cd /opt/vista
install -m 0755 deploy/vista-update /usr/local/bin/vista-update

# The repo is owned by druths so it can be worked in directly, but
# vista-update runs as root, and git refuses a repo owned by someone else.
chown -R druths:druths /opt/vista
git config --global --add safe.directory /opt/vista

# .env is not in the repo — it holds the secret key.
cat > .env <<'ENV'
VISTA_SECRET_KEY=<openssl rand -hex 32>
VISTA_CORS_ORIGINS=http://hub.t.internal:5190,http://<hub-tailscale-ip>:5190
VISTA_API_PORT=5191
VISTA_WEB_PORT=5190
ENV

docker compose -f docker-compose.prod.yml up -d --build

# Accounts are provisioned deliberately; there is no signup.
docker compose -f docker-compose.prod.yml exec api python -m vista users add you@example.com
```

Then sign in and set the Ark server, notes folder and brief locations from
**Settings** — no further CLI needed.

## State and backups

Everything Vista owns lives in the `vista_vista-data` volume: the account table
and each account's Ark token, encrypted with `VISTA_SECRET_KEY`.

**Back up the volume and `.env` together.** The volume alone is useless without
the key — losing the key means every account has to re-enter its Ark token.

```bash
docker run --rm -v vista_vista-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/vista-data-$(date +%F).tar.gz -C /data .
```

## Ports

Chosen to clear what hub already runs (relay on 5050/5051, lighthouse on 5172,
kokoro on 8880, headscale on 8080/3478, filestore on 8123, digest on 8124).
Change them in `.env`; `VISTA_API_PORT` is also compiled into the web client,
so the web image rebuilds when it changes.

## No TLS

Plain HTTP over the tailnet, matching how relay runs here. Two consequences
worth knowing:

- Chrome will not offer to **install the web client** as an app except from
  `localhost` or over HTTPS.
- The iOS app disables App Transport Security to allow it.

Both would be fixed by a certificate for a name hub answers to; the traffic is
already inside an encrypted WireGuard tunnel either way.
