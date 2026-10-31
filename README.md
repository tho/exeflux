# exeflux

[Miniflux](https://miniflux.app) + PostgreSQL 16 on
[exeslim](https://github.com/tho/exeslim). Two flavors from one `Dockerfile`:

| Flavor      | Listens on                    | Reached via            | Auth header            |
|-------------|-------------------------------|------------------------|------------------------|
| `exe`       | `127.0.0.1:8000`              | `https://$VM.exe.xyz`  | `X-ExeDev-Email`       |
| `tailscale` | `/run/miniflux/miniflux.sock` | Tailscale Serve        | `Tailscale-User-Login` |

Users are created on first visit from the header; password login is disabled.
The exe flavor trusts the header from any loopback client, so don't `share
set-public`. The tailscale flavor listens on a socket that only root, and so
tailscaled, can reach. PostgreSQL listens only on its socket, with peer
authentication.

## Deploy

Tags are `<build-id>-<flavor>` for `exe` and `tailscale`
([package page](https://github.com/tho/exeflux/pkgs/container/exeflux)).
`latest-<flavor>` moves and exe.dev caches it for up to an hour
([exeslim: tags](https://github.com/tho/exeslim#tags)).

```sh
ssh exe.dev new --name="$VM" --image=ghcr.io/tho/exeflux:<build-id>-<flavor>
ssh "$VM.exe.xyz" systemctl is-active svc-miniflux
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

Then follow the flavor's section. Each ends with the URL, which is also the
`BASE_URL` to set ([Configure](#configure)) before opening it.

### exe flavor

Nothing to set up on the VM: the exe.dev proxy already fronts port 8000 and
signs users in.

URL: `https://$VM.exe.xyz`.

### tailscale flavor

Tailscale Serve fronts the socket and the tailnet login becomes the Miniflux
user. HTTPS only, which needs MagicDNS and HTTPS certificates: both flavors set
`HTTPS=1` (Secure cookies, HSTS), so a session over plain `--http` never gets
its cookie back, and a browser does not treat http as private just because it
crosses a tailnet. Policy:

```jsonc
"tagOwners": { "tag:miniflux": [] },
"grants": [{ "src": ["<sources>"], "dst": ["tag:miniflux"], "ip": ["443"] }],
```

Delete any old `exeflux` machine first to avoid `exeflux-1`. Use a
non-reusable auth key for `tag:miniflux`.

```sh
ssh "$VM.exe.xyz" sudo tailscale up --hostname=exeflux --auth-key=<key>
ssh "$VM.exe.xyz" sudo tailscale set --auto-update
ssh "$VM.exe.xyz" sudo tailscale serve --bg --https=443 unix:/run/miniflux/miniflux.sock
```

`set --auto-update` is a no-op if the tailnet's "Auto-update new devices" is
on; see [Upgrade](#upgrade). State persists in `/var/lib/tailscale`.

URL: `https://exeflux.<tailnet>.ts.net`.

Optional [Tailscale Service](https://tailscale.com/docs/features/tailscale-services)
`svc:miniflux` (endpoint `tcp:443`) for a stable name across VMs:

```jsonc
"autoApprovers": { "services": { "svc:miniflux": ["tag:miniflux"] } },
"grants": [{ "src": ["<sources>"], "dst": ["svc:miniflux"], "ip": ["443"] }],
```

```sh
ssh "$VM.exe.xyz" sudo tailscale serve --service=svc:miniflux --https=443 unix:/run/miniflux/miniflux.sock
```

URL (update `BASE_URL`): `https://miniflux.<tailnet>.ts.net`.

## Configure

`/etc/miniflux.conf` is the package's config file, read by `svc-miniflux` and
by `miniflux -config-file`. The image appends its settings (see the
[`Dockerfile`](Dockerfile)); each flavor adds its listen address and header.
Per VM, append what differs and restart:

```sh
ssh "$VM.exe.xyz" 'echo BASE_URL=<url> | sudo tee -a /etc/miniflux.conf'
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

## Upgrade

### Miniflux

Read the [release notes](https://github.com/miniflux/v2/releases) for breaking
changes, then:

```sh
ssh "$VM.exe.xyz" sudo upgrade-miniflux -b /root/miniflux.dump [-s <sha256>] <version>
```

It follows [upstream's steps](https://miniflux.app/docs/upgrade.html): stops
`svc-miniflux`, flushes sessions (proxy auth signs users back in on their next
request), dumps and checks the backup if `-b`, installs, starts, and returns
once Miniflux reports ready. It refuses downgrades and keeps
`/etc/miniflux.conf`. `-s` checks the download against a checksum from
somewhere other than the download itself, such as the [Build](#build) command
run locally. Bump the `Dockerfile` `ARG`s to match.

No rollback. On failure, check `journalctl -u svc-miniflux`. To revert,
`dpkg -i --force-confold` the old `.deb`, then follow
[Backup and restore](#backup-and-restore) with this in place of its
`pg_restore` line:

```sh
ssh "$VM.exe.xyz" 'sudo cat /root/miniflux.dump | sudo -u postgres pg_restore -e -d miniflux'
```

### Base image

Bump `BASE` in the `Dockerfile` to a newer exeslim build id and rebuild. The VM
is stateful, so move to a new one with [Backup and restore](#backup-and-restore)
rather than replacing it in place
([exeslim: deploying and updating](https://github.com/tho/exeslim/blob/main/docs/deploying.md#deploying-and-updating)).

### Ubuntu and Tailscale

Unlike exeslim, the VM patches itself: `unattended-upgrades` installs Ubuntu
security updates daily and reboots right after any upgrade that needs it.
Miniflux is not an Ubuntu package, so it is not covered. Neither is Tailscale,
which [updates itself](https://tailscale.com/kb/1067/update) when
`tailscale set --auto-update` is on: Tailscale enables a release for
auto-update about a week after shipping it, sooner for security fixes, and the
client installs it with `apt-get` from `pkgs.tailscale.com`. The `Dockerfile`
pin is only a fresh VM's starting version. Check with:

```sh
ssh "$VM.exe.xyz" sudo cat /var/log/unattended-upgrades/unattended-upgrades.log
ssh "$VM.exe.xyz" tailscale version
```

## Build

```sh
docker build --target exe -t exeflux:exe .
docker build --target tailscale -t exeflux:tailscale .
curl -fsSL https://github.com/miniflux/v2/releases/download/<version>/miniflux_<version>_amd64.deb | sha256sum  # MINIFLUX_SHA256
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/<codename>.noarmor.gpg | sha256sum  # TAILSCALE_KEY_SHA256
```

CI builds, checks and boots both flavors as in
[exeslim's recipe](https://github.com/tho/exeslim/blob/main/docs/deploying.md#checking-the-profile-in-ci),
and pushes them to `ghcr.io/tho/exeflux` on push to `main`. A weekly run
publishes nothing; it proves the pinned inputs still build and boot.
