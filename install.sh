#!/usr/bin/env bash
set -euo pipefail

# Human-invoked fresh-server installer. It never enables DryRun, GMGN runtime,
# or any trading path. Binary trust comes from the offline Ed25519 signature.
repo='muxang/wind-monitor-release'
base='https://github.com/muxang/wind-monitor-release/releases/latest/download'
public_key_hex='1ab34f5688c2aba68328c34d6baff4d73606df5a6236195322d4e7b1205be23d'
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || { echo 'Linux x86_64 is required' >&2; exit 2; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'run as root' >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl gh jq openssl sqlite3 xxd
work="$(mktemp -d /tmp/wind-monitor-install.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT
for asset in wind-monitor-linux-x86_64 wind-monitor-updater-linux-x86_64 release-manifest.json release-manifest.sig; do
  curl --fail --location --silent --show-error --max-filesize 134217728 --output "$work/$asset" "$base/$asset"
done

printf '302a300506032b6570032100%s' "$public_key_hex" | xxd -r -p >"$work/release-public.der"
openssl pkey -pubin -inform DER -in "$work/release-public.der" -out "$work/release-public.pem" >/dev/null
base64 -d "$work/release-manifest.sig" >"$work/release-manifest.sig.bin"
openssl pkeyutl -verify -pubin -inkey "$work/release-public.pem" -rawin \
  -in "$work/release-manifest.json" -sigfile "$work/release-manifest.sig.bin" >/dev/null
verify_asset() {
  local file="$1" sha_field="$2" size_field="$3" expected_sha expected_size actual_sha actual_size
  expected_sha="$(jq -er ".$sha_field" "$work/release-manifest.json")"
  expected_size="$(jq -er ".$size_field" "$work/release-manifest.json")"
  actual_sha="$(sha256sum "$work/$file" | cut -d' ' -f1)"; actual_size="$(stat -c %s "$work/$file")"
  [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" && "$actual_size" -le 134217728 ]]
}
verify_asset wind-monitor-linux-x86_64 binary_sha256 binary_size
verify_asset wind-monitor-updater-linux-x86_64 updater_sha256 updater_size
[[ "$(jq -er '.channel' "$work/release-manifest.json")" == stable ]]
if [[ "${WIND_MONITOR_INSTALL_VERIFY_ONLY:-0}" == 1 ]]; then
  echo "Verified signed Wind Monitor $(jq -r .version "$work/release-manifest.json") installer assets."
  exit 0
fi

id wind-monitor >/dev/null 2>&1 || useradd --system --home /var/lib/wind-monitor --shell /usr/sbin/nologin wind-monitor
install -d -o root -g root -m 0755 /opt/wind-monitor/bin /opt/wind-monitor/ops
install -d -o wind-monitor -g wind-monitor -m 0700 /var/lib/wind-monitor /var/lib/wind-monitor/backups
install -o root -g root -m 0755 "$work/wind-monitor-linux-x86_64" /opt/wind-monitor/bin/wind-monitor
install -o root -g root -m 0755 "$work/wind-monitor-updater-linux-x86_64" /opt/wind-monitor/bin/wind-monitor-updater
cat >/opt/wind-monitor/ops/production_deploy.sh <<'DEPLOY'
#!/usr/bin/env bash
set -euo pipefail
candidate="${1:?candidate required}"; service="${2:-wind-monitor.service}"
binary="${WIND_MONITOR_BINARY:-/opt/wind-monitor/bin/wind-monitor}"
database="${WIND_MONITOR_DB:-/var/lib/wind-monitor/app.db}"
health="${WIND_MONITOR_HEALTH_URL:-http://127.0.0.1:3000/healthz}"
[[ -x "$candidate" && -f "$database" ]] || exit 2
free="$(df --output=avail -B1 "$(dirname "$database")" | tail -1 | tr -d ' ')"
need="$(( $(stat -c %s "$database") * 3 + $(stat -c %s "$candidate") * 2 + 104857600 ))"
(( free > need )) || exit 2
stamp="$(date -u +%Y%m%dT%H%M%SZ)"; backup="/var/lib/wind-monitor/backups/pre-upgrade-$stamp.db"
sqlite3 "$database" ".backup '$backup'"; chmod 0600 "$backup"
incoming="$binary.new"; previous="$binary.previous"
install -o root -g root -m 0755 "$candidate" "$incoming"
rollback(){ systemctl stop "$service" || true; [[ -f "$previous" ]] && mv -f "$previous" "$binary"; sqlite3 "$database" ".restore '$backup'"; systemctl start "$service" || true; }
trap rollback ERR
systemctl stop "$service"; cp --preserve=mode,ownership,timestamps "$binary" "$previous"; mv -f "$incoming" "$binary"; systemctl start "$service"
for _ in $(seq 1 30); do curl --fail --silent "$health" >/dev/null && break; sleep 1; done
curl --fail --silent "$health" >/dev/null; trap - ERR
DEPLOY
chmod 0755 /opt/wind-monitor/ops/production_deploy.sh

cat >/etc/systemd/system/wind-monitor.service <<'UNIT'
[Unit]
Description=Wind Monitor Paper-only service
After=network-online.target
Wants=network-online.target
[Service]
User=wind-monitor
Group=wind-monitor
WorkingDirectory=/var/lib/wind-monitor
Environment=WIND_MONITOR_DATABASE_URL=sqlite:///var/lib/wind-monitor/app.db
Environment=WIND_MONITOR_DEPLOY_SCRIPT=/opt/wind-monitor/ops/production_deploy.sh
Environment=WIND_MONITOR_SERVICE=wind-monitor.service
Environment=WIND_MONITOR_DATA_DIR=/var/lib/wind-monitor
Environment=RUST_LOG=info,tower_http=warn
ExecStart=/opt/wind-monitor/bin/wind-monitor
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/wind-monitor
LockPersonality=true
RestrictSUIDSGID=true
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200
[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/wind-monitor-updater.service <<'UNIT'
[Unit]
Description=Wind Monitor signed GitHub updater
After=network-online.target
[Service]
Type=oneshot
User=root
UMask=0077
Environment=WIND_MONITOR_DATA_DIR=/var/lib/wind-monitor
Environment=WIND_MONITOR_DATABASE_URL=sqlite:///var/lib/wind-monitor/app.db
ExecStart=/opt/wind-monitor/bin/wind-monitor-updater run
PrivateTmp=true
ProtectHome=true
LockPersonality=true
RestrictSUIDSGID=true
UNIT
cat >/etc/systemd/system/wind-monitor-updater.timer <<'UNIT'
[Unit]
Description=Periodic signed stable release check
[Timer]
OnBootSec=15m
OnUnitActiveSec=15m
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
UNIT
install -d -m 0755 /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/90-wind-monitor-limits.conf <<'JOURNAL'
[Journal]
SystemMaxUse=512M
SystemKeepFree=1G
MaxRetentionSec=14day
JOURNAL
systemctl daemon-reload
systemctl try-restart systemd-journald.service || true
systemctl enable --now wind-monitor.service wind-monitor-updater.timer
echo "Installed signed Wind Monitor $(jq -r .version "$work/release-manifest.json")."
echo 'Safe defaults remain: configure Feed in the admin UI; Execution and GMGN runtime are disabled.'
