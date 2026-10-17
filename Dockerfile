# exeflux: Miniflux + PostgreSQL on exeslim, in two flavors. See README.md.
#
#   docker build --target exe -t exeflux:exe .
#   docker build --target tailscale -t exeflux:tailscale .

# Immutable <date>.<run>.<attempt> tag; exeslim's <date> tag moves.
ARG BASE=ghcr.io/tho/exeslim:2026-10-16.8.1
FROM ${BASE} AS common
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ARG MINIFLUX_VERSION=2.3.3
ARG MINIFLUX_SHA256=14712f3852a7e6716676b9a827597febf098da9ae926b3ca82b594ad3d16e759

RUN curl -fsSLo /tmp/miniflux.deb \
		"https://github.com/miniflux/v2/releases/download/${MINIFLUX_VERSION}/miniflux_${MINIFLUX_VERSION}_amd64.deb" \
	&& echo "${MINIFLUX_SHA256}  /tmp/miniflux.deb" | sha256sum -c - \
	&& apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		postgresql-16 /tmp/miniflux.deb \
		unattended-upgrades update-notifier-common \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* /tmp/miniflux.deb \
	# exeslim empties this after its last apt layer; keep it empty after ours.
	&& : >/etc/machine-id

# exeslim masks these; turn them back on, rebooting when an upgrade needs it.
RUN systemctl unmask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
	&& systemctl enable apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
	&& printf '%s\n' \
		'APT::Periodic::Update-Package-Lists "1";' \
		'APT::Periodic::Unattended-Upgrade "1";' >/etc/apt/apt.conf.d/20auto-upgrades \
	&& echo 'Unattended-Upgrade::Automatic-Reboot "true";' >/etc/apt/apt.conf.d/52exeflux-reboot \
	&& rm /etc/apt/apt.conf.d/docker-disable-periodic-update

RUN sed -i '1i host miniflux miniflux 127.0.0.1/32 trust' /etc/postgresql/16/main/pg_hba.conf \
	&& pg_ctlcluster 16 main start \
	&& runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
		-c 'CREATE ROLE miniflux LOGIN' \
		-c 'CREATE DATABASE miniflux OWNER miniflux' \
	&& pg_ctlcluster 16 main stop

RUN printf '%s\n' \
		'DATABASE_URL=postgres://miniflux@127.0.0.1/miniflux?sslmode=disable' \
		'AUTH_PROXY_USER_CREATION=1' \
		'DISABLE_LOCAL_AUTH=1' \
		'HTTPS=1' \
		'MEDIA_PROXY_MODE=all' \
		'FETCH_YOUTUBE_WATCH_TIME=1' \
		'POLLING_LIMIT_PER_HOST=4' >>/etc/miniflux.conf

COPY --chmod=0644 svc-miniflux.service /etc/systemd/system/
COPY --chmod=0755 upgrade-miniflux /usr/local/sbin/
RUN systemctl disable miniflux.service \
	&& systemctl enable svc-miniflux.service

FROM common AS exe

# Port 8000 is exeslim's EXPOSEd default, so https://$VM.exe.xyz/ lands here.
# The exe.dev proxy arrives over loopback.
RUN printf '%s\n' \
		'LISTEN_ADDR=127.0.0.1:8000' \
		'AUTH_PROXY_HEADER=X-ExeDev-Email' \
		'TRUSTED_REVERSE_PROXY_NETWORKS=127.0.0.1/32' >>/etc/miniflux.conf

LABEL org.opencontainers.image.title="exeflux" \
	org.opencontainers.image.description="Miniflux and PostgreSQL on exeslim, served through the exe.dev proxy."

FROM common AS tailscale

ARG TAILSCALE_VERSION=1.104.1
ARG TAILSCALE_KEY_SHA256=3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39

RUN . /etc/os-release \
	&& curl -fsSLo /usr/share/keyrings/tailscale-archive-keyring.gpg \
		https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.noarmor.gpg \
	&& echo "${TAILSCALE_KEY_SHA256}  /usr/share/keyrings/tailscale-archive-keyring.gpg" | sha256sum -c - \
	&& curl -fsSLo /etc/apt/sources.list.d/tailscale.list \
		https://pkgs.tailscale.com/stable/ubuntu/${VERSION_CODENAME}.tailscale-keyring.list \
	&& apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		"tailscale=${TAILSCALE_VERSION}" \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* \
	&& : >/etc/machine-id

# 10000 is outside the 3000 to 9999 range the exe.dev proxy forwards.
RUN printf '%s\n' \
		'LISTEN_ADDR=127.0.0.1:10000' \
		'AUTH_PROXY_HEADER=Tailscale-User-Login' \
		'TRUSTED_REVERSE_PROXY_NETWORKS=127.0.0.1/32' >>/etc/miniflux.conf \
	&& sed -i 's/^FLAGS=.*/FLAGS="--tun=userspace-networking"/' /etc/default/tailscaled \
	&& grep -qx 'FLAGS="--tun=userspace-networking"' /etc/default/tailscaled \
	&& systemctl enable tailscaled.service

LABEL org.opencontainers.image.title="exeflux" \
	org.opencontainers.image.description="Miniflux and PostgreSQL on exeslim, served over Tailscale Serve."
