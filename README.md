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

Tags are `<build-id>-exe` and `<build-id>-tailscale`
([package page](https://github.com/tho/exeflux/pkgs/container/exeflux)); the
moving `latest-`, `<date>-` and `<sha>-` tags are as for
[exeslim](https://github.com/tho/exeslim#tags).

```sh
ssh exe.dev new --name="$VM" --image=ghcr.io/tho/exeflux:<build-id>-<flavor>
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

Then set `BASE_URL` ([Configure](#configure)) and open the URL.

### tailscale flavor

HTTPS only; it needs MagicDNS and HTTPS certificates. Every flavor sets
`HTTPS=1` (Secure cookies, HSTS), so plain `--http` would never get its session
cookie back, and browsers do not know that http over a tailnet is private.
Policy:

```jsonc
"tagOwners": { "tag:miniflux": [] },
"grants": [{ "src": ["<sources>"], "dst": ["tag:miniflux"], "ip": ["443"] }],
```

Delete any old `exeflux` machine first to avoid `exeflux-1`. Use a one-off (non-reusable) auth key for `tag:miniflux`.

```sh
ssh "$VM.exe.xyz" sudo tailscale up --hostname=exeflux --auth-key=<key>
ssh "$VM.exe.xyz" sudo tailscale serve --bg --https=443 127.0.0.1:10000
```

URL (set as `BASE_URL`): `https://exeflux.<tailnet>.ts.net/`. State persists in `/var/lib/tailscale`.

Optional [Tailscale Service](https://tailscale.com/docs/features/tailscale-services)
`svc:miniflux` (endpoint `tcp:443`) for a stable name across VMs:

```jsonc
"autoApprovers": { "services": { "svc:miniflux": ["tag:miniflux"] } },
"grants": [{ "src": ["<sources>"], "dst": ["svc:miniflux"], "ip": ["443"] }],
```

```sh
ssh "$VM.exe.xyz" sudo tailscale serve --service=svc:miniflux --https=443 127.0.0.1:10000
```

URL (update `BASE_URL`): `https://miniflux.<tailnet>.ts.net/`.

## Configure

`/etc/miniflux.conf` is the package's config file, read by `svc-miniflux` and
by `miniflux -config-file`. The image appends the proxy-auth, media-proxy and
polling settings (see the [`Dockerfile`](Dockerfile)); each flavor adds its
listen address and header. Per VM, append what differs and restart:

```sh
ssh "$VM.exe.xyz" 'echo BASE_URL=<proto>://<url> | sudo tee -a /etc/miniflux.conf'
ssh "$VM.exe.xyz" sudo systemctl restart svc-miniflux
```

`BASE_URL` is required for API clients and media-proxy links. Anything else is
in Miniflux's [configuration reference](https://miniflux.app/docs/configuration.html).
Upgrades keep the file.

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

Miniflux:

```sh
ssh "$VM.exe.xyz" sudo upgrade-miniflux -b /root/miniflux.dump [-s <sha256>] <version>
```

Read the [release notes](https://github.com/miniflux/v2/releases) for breaking
changes first. Follows [upstream's steps](https://miniflux.app/docs/upgrade.html):
stops `svc-miniflux`, flushes sessions (proxy auth signs users back in on their
next request), dumps and checks the backup if `-b`, installs, starts.  Refuses
downgrades, keeps `/etc/miniflux.conf`, returns once Miniflux reports ready.
`-s` checks the download against a checksum from somewhere other than the
download itself. No rollback: on
failure check `journalctl -u svc-miniflux`; to revert, `dpkg -i --force-confold`
the old `.deb`, then follow the restore steps in Backup and restore, replacing
its `pg_restore` line with:

```sh
ssh "$VM.exe.xyz" 'sudo cat /root/miniflux.dump | sudo -u postgres pg_restore -e -d miniflux'
```

Bump the `Dockerfile` `ARG`s to match.

The base: bump `BASE` in the `Dockerfile` to a newer exeslim build id and
rebuild. The VM is stateful, so move to a new one with
[Backup and restore](#backup-and-restore) rather than replacing it in place
([exeslim: deploying and updating](https://github.com/tho/exeslim/blob/main/docs/deploying.md#deploying-and-updating)).

Unlike exeslim, the VM patches itself: Ubuntu security updates install daily
via `unattended-upgrades`, which reboots the VM right after any upgrade that
needs it. Miniflux and Tailscale are not covered; they come from outside
Ubuntu's security pocket. Check with:

```sh
ssh "$VM.exe.xyz" sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
```

## Build

```sh
docker build --target exe -t exeflux:exe .
docker build --target tailscale -t exeflux:tailscale .
curl -fsSL https://github.com/miniflux/v2/releases/download/<version>/miniflux_<version>_amd64.deb | sha256sum  # MINIFLUX_SHA256
```

CI builds, checks and boots both flavors as in
[exeslim's recipe](https://github.com/tho/exeslim/blob/main/docs/deploying.md#checking-the-profile-in-ci),
and pushes them to `ghcr.io/tho/exeflux` on push to `main` and weekly.
