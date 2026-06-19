# Docker Compose deployment

A self-contained deployment that runs the three processes as containers behind
[Caddy](https://caddyserver.com), which terminates TLS with an automatic Let's
Encrypt certificate — so the OAuth-capable clients (which require public HTTPS)
work out of the box.

```
  Internet ──443──▶ caddy  (TLS, Let's Encrypt)
                      │   edge network
                      ▼
                   gateway  (auth_gateway.py, OAuth + Basic Auth)
                      │   internal network (no outbound internet)
              ┌───────┴────────┐
              ▼                ▼
         basicmemory        wsgidav
          (MCP :8000)      (WebDAV :8002)
              └──── notes volume ────┘
```

The gateway, Basic Memory and WsgiDAV all run from **one image** (they share the
same `uv` dependency set); each service just runs a different command. Only
Caddy publishes ports. Basic Memory and WsgiDAV sit on an `internal` network
with no internet access and are reachable only through the gateway.

For connecting clients and the full configuration reference, see the
[main README](README.md#connecting-clients).

## Requirements

- Docker Engine with the Compose plugin (`docker compose`).
- A domain whose DNS **A/AAAA record points at this host**.
- Ports **80 and 443** reachable from the internet (Caddy needs both for the
  ACME challenge and to serve HTTPS).

## Setup

```bash
git clone https://github.com/yeah/basic-memory-oauth-server.git
cd basic-memory-oauth-server
cp .env.docker.example .env
openssl rand -hex 32        # CLIENT_SECRET
openssl rand -hex 32        # JWT_SECRET
```

Edit `.env` and set:

```ini
DOMAIN=memory.example.com           # your real domain
CLIENT_ID=basic-memory
CLIENT_SECRET=<first openssl value>
JWT_SECRET=<second openssl value>
LOGIN_PASSWORD=<a long, random password>
ALLOWED_REDIRECT_HOSTS=claude.ai,chatgpt.com,callback.mistral.ai
```

`BASE_URL` is derived automatically as `https://<DOMAIN>`. Then:

```bash
docker compose up -d --build
docker compose ps          # all should become healthy
docker compose logs -f gateway
```

On first start Caddy obtains the certificate (watch `docker compose logs caddy`).
Once healthy, your endpoints are:

- `https://<DOMAIN>/mcp`  — MCP, for Claude / ChatGPT / Mistral
- `https://<DOMAIN>/dav`  — WebDAV, for Obsidian

Connect clients exactly as in the [main README](README.md#connecting-clients);
the only difference is that `BASE_URL` is your domain. The favicon redirect and
all `/.well-known` discovery endpoints are served by the gateway through Caddy
automatically — there is no per-path backend wiring to do (unlike Uberspace).

## Data and backups

Your notes and the Basic Memory index live in the `notes` volume
(`/data/basic-memory` and `/data/.basic-memory` inside the containers). Back it
up with:

```bash
docker run --rm -v basic-memory_notes:/data -v "$PWD":/backup alpine \
  tar czf /backup/notes-backup.tar.gz -C /data .
```

Certificates persist in the `caddy_data` volume, so restarts do not re-request
them.

## Updating

```bash
git pull
docker compose up -d --build
```

Access tokens survive a restart (verified via `JWT_SECRET`); refresh tokens are
in-memory and clients simply re-authenticate when next needed.

## Behind your own reverse proxy (no Caddy)

If you already run nginx, Traefik, a Cloudflare Tunnel, etc., drop Caddy and let
your proxy terminate TLS:

1. Delete (or don't start) the `caddy` service.
2. Publish the gateway to the host by adding to the `gateway` service:
   ```yaml
       ports:
         - "127.0.0.1:8001:8001"
   ```
3. Point your proxy at `http://127.0.0.1:8001`.

`BASE_URL` must still be the **public HTTPS URL** your proxy serves. Only the
*client* callback hosts need to be in `ALLOWED_REDIRECT_HOSTS` — your own domain
does not need to be listed there.

## Notes

- **Single user.** One password guards both OAuth and WebDAV; the same security
  model and brute-force throttle as the user-services setup apply (see the
  [main README's security notes](README.md#security-notes)).
- **Non-root.** The containers fix volume ownership and then drop to an
  unprivileged user via `gosu`.
- **No internet for the data services.** `basicmemory` and `wsgidav` are on an
  `internal` Docker network. If a future Basic Memory feature needs outbound
  access, remove `internal: true` from the `internal` network in
  `docker-compose.yml`.
