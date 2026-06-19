# Linux user services (Uberspace)

Run the three processes — the gateway, Basic Memory and WsgiDAV — as **systemd
user services** behind your platform's web server, with no root and no Docker.
These instructions target [Uberspace 8](https://uberspace.de), where `uv` is
preinstalled and the `uberspace` CLI configures systemd-user services and the
web backend for you. The same approach works on any host with per-user systemd
— see [Other Linux hosts](#other-linux-hosts) at the end.

For connecting clients and the full configuration reference, see the
[main README](README.md#connecting-clients).

## Requirements

- An Uberspace 8 account (referred to as user `ubernaut` below — replace with
  your own username throughout)
- SSH access to your Uberspace

`uv` is already installed on Uberspace 8 (at `/usr/bin/uv`), so there is nothing
to install for the Python toolchain.

## 1. Get this project

```bash
git clone https://github.com/yeah/basic-memory-oauth-server.git ~/auth_gateway
cd ~/auth_gateway
uv sync                    # installs everything (incl. Basic Memory) from uv.lock
```

`uv sync` installs all dependencies — the gateway, WsgiDAV, **and Basic Memory
itself** — at the exact versions pinned in `uv.lock`. Nothing else to install
by hand. Your notes will live as Markdown files under `~/basic-memory` by
default.

## 2. Create your configuration

```bash
cp .env.example .env
```

Generate two strong secrets:

```bash
openssl rand -hex 32       # use for CLIENT_SECRET
openssl rand -hex 32       # use for JWT_SECRET
```

Edit `.env` and set at least:

```ini
BASE_URL=https://ubernaut.uber.space
CLIENT_ID=basic-memory
CLIENT_SECRET=<first openssl value>
JWT_SECRET=<second openssl value>
LOGIN_PASSWORD=<a long, randomly generated password>
ALLOWED_REDIRECT_HOSTS=claude.ai,chatgpt.com,callback.mistral.ai
```

`LOGIN_PASSWORD` is used both for the OAuth browser login and as the WebDAV
password. The WebDAV username defaults to `CLIENT_ID`. Make it long and random:
it is the one human-chosen secret, and although a global throttle slows guessing
(see the [README](README.md#security-notes)), a strong password is the real
protection.

OAuth callbacks are restricted so the authorization code can only go to a
client you trust. A redirect URI is allowed if **either** check passes:

- `ALLOWED_REDIRECT_HOSTS` — comma-separated hosts; an `https` redirect URI
  whose host matches exactly is accepted, whatever the path. This is the
  practical option, because some clients mint a per-connector callback path on
  a fixed host. Known hosts: Claude → `claude.ai`, ChatGPT → `chatgpt.com`
  (path varies, e.g. `/connector/oauth/<id>`), Mistral → `callback.mistral.ai`.
- `ALLOWED_REDIRECT_URIS` — comma-separated **exact** full-URI matches, to pin
  one specific callback instead of trusting a whole host.

At least one of the two must be set, or every `/authorize` is rejected. Host
matching is an exact host comparison over `https` (no subdomain wildcards), so
lookalikes like `chatgpt.com.evil.com` are rejected. A rejected `redirect_uri`
is logged (`journalctl --user -u auth_gateway`) so you can see the exact value
your client uses and allow its host or URI.

The gateway also **refuses to start** if `CLIENT_SECRET`, `JWT_SECRET` or
`LOGIN_PASSWORD` is empty, so a misconfigured deployment fails loudly instead
of running with no effective authentication.

Protect the file (it contains secrets):

```bash
chmod 600 .env
```

> **Important:** `BASE_URL` must exactly match the public URL of your Uberspace,
> without the `/mcp` suffix. If it is wrong, the OAuth discovery breaks for
> browser clients.

## 3. Point WsgiDAV at your notes

Edit `wsgidav.yaml` and set the `provider_mapping` to the absolute path of your
notes (WsgiDAV does not expand `~`):

```yaml
provider_mapping:
  "/dav": "/home/ubernaut/basic-memory"
```

Leave `simple_dc` on anonymous access — the gateway is the gatekeeper, WsgiDAV
only ever listens on `127.0.0.1`.

## 4. Create the three services

Uberspace 8 uses systemd user services. We run **three**, all started with
`--workdir` so uv finds the project and the gateway finds `.env`.

**Basic Memory** — MCP server on `127.0.0.1:8000`:

```bash
uberspace service add basicmemory \
  "/usr/bin/uv run basic-memory mcp --transport streamable-http --host 127.0.0.1 --port 8000" \
  --workdir "$HOME/auth_gateway"
```

**WsgiDAV** — WebDAV server on `127.0.0.1:8002`:

```bash
uberspace service add wsgidav \
  "/usr/bin/uv run wsgidav --config wsgidav.yaml" \
  --workdir "$HOME/auth_gateway"
```

**The gateway** — the single public entrypoint, binds `0.0.0.0:8001`:

```bash
uberspace service add auth_gateway \
  "/usr/bin/uv run python auth_gateway.py" \
  --workdir "$HOME/auth_gateway"
```

> The gateway must bind `0.0.0.0` because that is what the web backend connects
> to. Basic Memory and WsgiDAV stay on `127.0.0.1`: each Uberspace lives in its
> own network namespace with its own loopback, so `127.0.0.1` is private to your
> account and unreachable by other users on the host.

Check all three:

```bash
systemctl --user status auth_gateway --no-pager
systemctl --user status basicmemory  --no-pager
systemctl --user status wsgidav      --no-pager
```

If the gateway refuses to start with "missing required secret(s)", fill those
in in `.env`. If it logs `ModuleNotFoundError`, the working directory is wrong —
verify `--workdir` points at the cloned repo and that `.env` exists there.

## 5. Wire up the web backends

Map only the specific gateway paths, so `/` stays free for other uses. The
gateway forwards `/mcp` to Basic Memory and `/dav` to WsgiDAV after checking
auth; never point a backend straight at port 8000 or 8002.

```bash
uberspace web backend del /          # remove the default Apache backend on these paths if present
uberspace web backend add /mcp port 8001
uberspace web backend add /dav port 8001
uberspace web backend add /authorize port 8001
uberspace web backend add /token port 8001
uberspace web backend add /.well-known/oauth-protected-resource port 8001
uberspace web backend add /.well-known/oauth-authorization-server port 8001
uberspace web backend add /favicon.ico port 8001
uberspace web backend list
```

> `/` itself is no longer routed to the gateway, leaving it available for
> anything else you host on this Uberspace.
>
> The `/favicon.ico` mapping is optional. The gateway answers it with a 302
> redirect to the Basic Memory logo on basicmemory.com, so favicon services
> (such as the one Claude uses to show a connector icon) find an icon for the
> domain. Note that these services cache per-domain for a long time, so any
> change may take a while to appear.

That's it — your endpoints are `https://ubernaut.uber.space/mcp` and `/dav`. See
the [main README](README.md#connecting-clients) to connect clients.

## Operating notes

- **Updating dependencies:** `uv add <pkg>` / `uv remove <pkg>` updates
  `pyproject.toml` and `uv.lock`. Re-deploy with `uv sync` and restart the
  services.
- **Logs:** `journalctl --user -u auth_gateway -n 50 --no-pager` (likewise for
  `basicmemory` and `wsgidav`).
- **Token / restart behaviour and forcing a fresh OAuth flow:** see the
  [README operating notes](README.md#operating-notes).

## Other Linux hosts

On a host without the `uberspace` CLI, do the equivalent by hand:

- Create three `systemd --user` unit files (or use your process manager) that
  run the same commands as in step 4, each with the cloned repo as the working
  directory. Enable lingering (`loginctl enable-linger $USER`) so they keep
  running after you log out.
- Put a web server (nginx, Caddy, …) in front, terminating TLS and reverse-
  proxying the gateway's paths (`/mcp`, `/dav`, `/authorize`, `/token`,
  `/.well-known/*`, `/favicon.ico`) to `127.0.0.1:8001`. Never expose ports
  8000 or 8002.
- Set `BASE_URL` to your public HTTPS URL.

If Docker is available, the [Docker Compose deployment](DOCKER.md) does all of
this for you.
