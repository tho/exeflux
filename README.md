# exeflux

[Miniflux](https://miniflux.app) + PostgreSQL 16 on
[exeslim](https://github.com/tho/exeslim). Two flavors from one `Dockerfile`:

| Flavor      | Listens on        | Reached via                    | Auth header            |
|-------------|-------------------|--------------------------------|------------------------|
| `exe`       | `127.0.0.1:8000`  | `https://$VM.exe.xyz/`         | `X-ExeDev-Email`       |
| `tailscale` | `127.0.0.1:10000` | Tailscale Serve                | `Tailscale-User-Login` |

Users are created on first visit from the header; password login is disabled.
Miniflux trusts the header from any loopback client, so don't `share
set-public` (exe) or `share port` (tailscale).

## Deploy

```sh
ssh exe.dev new --name="$VM" --image=ghcr.io/tho/exeflux:<tag>
ssh "$VM.exe.xyz" sudo miniflux -config-file /etc/miniflux.conf -healthcheck auto
```

Create the admin **before the first visit** (a visit creates a non-admin and
`-create-admin` then skips silently). Username is the proxy login; the
password is unused.

```sh
ssh -t "$VM.exe.xyz" sudo miniflux -config-file /etc/miniflux.conf -create-admin
```

Or promote an existing user (expect `UPDATE 1`):

```sh
ssh "$VM.exe.xyz" sudo -u postgres psql miniflux \
  -c "UPDATE users SET is_admin = true WHERE username = LOWER('<login>')"
```

Set `BASE_URL` for API clients and media-proxy links:

```sh
ssh "$VM.exe.xyz" 'echo BASE_URL=<url> | sudo tee -a /etc/miniflux.conf'
ssh "$VM.exe.xyz" sudo systemctl restart svc-miniflux
```

### tailscale flavor

`--<proto>=<port>` is `--https=443` (needs MagicDNS and HTTPS certificates) or `--http=80`. Policy:

```jsonc
"tagOwners": { "tag:miniflux": [] },
"grants": [{ "src": ["<sources>"], "dst": ["tag:miniflux"], "ip": ["<port>"] }],
```

Delete any old `exeflux` machine first to avoid `exeflux-1`. Use a one-off (non-reusable) auth key for `tag:miniflux`.

```sh
ssh "$VM.exe.xyz" sudo tailscale up --hostname=exeflux --auth-key=<key>
ssh "$VM.exe.xyz" sudo tailscale serve --bg --<proto>=<port> 127.0.0.1:10000
```

URL (set as `BASE_URL` above): `<proto>://exeflux.<tailnet>.ts.net/`. State persists in `/var/lib/tailscale`.

Optional [Tailscale Service](https://tailscale.com/docs/features/tailscale-services)
`svc:miniflux` (endpoint `tcp:<port>`) for a stable name across VMs:

```jsonc
"autoApprovers": { "services": { "svc:miniflux": ["tag:miniflux"] } },
"grants": [{ "src": ["<sources>"], "dst": ["svc:miniflux"], "ip": ["<port>"] }],
```

```sh
ssh "$VM.exe.xyz" sudo tailscale serve --service=svc:miniflux --<proto>=<port> 127.0.0.1:10000
```

URL (update `BASE_URL`): `<proto>://miniflux.<tailnet>.ts.net/`.

## Backup and restore

Database only; keep `/etc/miniflux.conf` separately.

```sh
ssh "$VM.exe.xyz" sudo -u postgres pg_dump -Fc miniflux >miniflux.dump
```

Restore into a fresh database on the same or newer Miniflux version:

```sh
ssh "$VM.exe.xyz" sudo systemctl stop svc-miniflux
ssh "$VM.exe.xyz" sudo -u postgres dropdb miniflux
ssh "$VM.exe.xyz" sudo -u postgres createdb -O miniflux miniflux
ssh "$VM.exe.xyz" sudo -u postgres pg_restore -e -d miniflux <miniflux.dump
ssh "$VM.exe.xyz" sudo systemctl start svc-miniflux
```

Across flavors, rename the user before the first visit:

```sh
ssh "$VM.exe.xyz" sudo -u postgres psql miniflux \
  -c "UPDATE users SET username = LOWER('<new>') WHERE username = LOWER('<old>')"
```

## Upgrade

```sh
ssh "$VM.exe.xyz" sudo upgrade-miniflux -b /root/miniflux.dump <version>
```

Refuses downgrades, keeps `/etc/miniflux.conf`, waits 60s for health. No
rollback: on failure check `journalctl -u svc-miniflux`; to revert,
`dpkg -i --force-confold` the old `.deb`, then follow the restore steps in
Backup and restore, replacing its `pg_restore` line with:

```sh
ssh "$VM.exe.xyz" 'sudo cat /root/miniflux.dump | sudo -u postgres pg_restore -e -d miniflux'
```

Bump the `Dockerfile` `ARG`s to match.

## Build

```sh
docker build --target exe -t exeflux:exe .
docker build --target tailscale -t exeflux:tailscale .
curl -fsSL https://github.com/miniflux/v2/releases/download/<version>/miniflux_<version>_amd64.deb | sha256sum  # MINIFLUX_SHA256
```

CI builds, boots, and pushes both flavors to `ghcr.io/tho/exeflux` on push
to `main` and weekly.
