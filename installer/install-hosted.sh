#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_AGENT_SCRIPT="${SCRIPT_DIR}/update-agent.py"
UPDATE_AGENT_SERVICE="${SCRIPT_DIR}/media-vision-update-agent.service"

DEFAULT_DISK_GIB=16
DEFAULT_CORES=2
DEFAULT_MEMORY_MIB=2048
DEFAULT_SWAP_MIB=512
DEFAULT_HOSTNAME=media-vision
DEFAULT_BRIDGE=vmbr0
DEFAULT_TEMPLATE_STORAGE=local
DEFAULT_IMAGE=ghcr.io/zemerdon/media-vision@sha256:77d77e06b1bcec050355d60fc7aaded704d37d0f86b6970812212a7b7f20f63c
DEFAULT_UPDATE_CHANNEL=develop
DEFAULT_METADATA_URL=""

VMID=""
STORAGE=""
TEMPLATE_STORAGE="$DEFAULT_TEMPLATE_STORAGE"
HOSTNAME="$DEFAULT_HOSTNAME"
BRIDGE="$DEFAULT_BRIDGE"
IP_CONFIG=dhcp
GATEWAY=""
DISK_GIB="$DEFAULT_DISK_GIB"
CORES="$DEFAULT_CORES"
MEMORY_MIB="$DEFAULT_MEMORY_MIB"
SWAP_MIB="$DEFAULT_SWAP_MIB"
IMAGE="$DEFAULT_IMAGE"
UPDATE_CHANNEL="$DEFAULT_UPDATE_CHANNEL"
METADATA_URL="$DEFAULT_METADATA_URL"
METADATA_KEY_FILE=""
DOWNLOADS_HOST=""
SERIES_HOST=""
MOVIES_HOST=""

usage() {
    cat <<'EOF'
Usage: install-hosted.sh --vmid ID --storage STORAGE --metadata-url URL --metadata-key-file FILE [options]

Creates an unprivileged Debian 13 LXC for Media Vision Hosted Metadata mode,
installs Docker, pulls the selected GHCR image, and starts Media Vision.

Required:
  --vmid ID                  Proxmox VMID for the new LXC
  --storage STORAGE          Proxmox storage for the 16 GiB root disk
  --metadata-url URL         Hosted metadata API URL
  --metadata-key-file FILE   Existing file containing the hosted metadata API key

Options:
  --template-storage NAME    Proxmox storage for Debian template (default: local)
  --hostname NAME            LXC hostname (default: media-vision)
  --bridge NAME              Network bridge (default: vmbr0)
  --ip VALUE                 dhcp or CIDR address (default: dhcp)
  --gateway ADDRESS          Required with a static --ip
  --disk-size GIB            Root disk size (default: 16)
  --cores N                  CPU cores (default: 2)
  --memory MIB               RAM (default: 2048)
  --swap MIB                 Swap (default: 512)
  --image IMAGE              Container image (default: v1.0.0 immutable public pre-release digest)
  --update-channel CHANNEL   Media Vision update channel: develop or stable (default: develop)
  --metadata-url URL         Hosted metadata API URL
  --downloads-host PATH      Optional Proxmox-host path bind-mounted to /srv/media-vision/downloads
  --series-host PATH         Optional Proxmox-host path bind-mounted to /srv/media-vision/series
  --movies-host PATH         Optional Proxmox-host path bind-mounted to /srv/media-vision/movies
  -h, --help                 Show this help

The script never destroys an LXC automatically on failure.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vmid) VMID="$2"; shift 2 ;;
        --storage) STORAGE="$2"; shift 2 ;;
        --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
        --hostname) HOSTNAME="$2"; shift 2 ;;
        --bridge) BRIDGE="$2"; shift 2 ;;
        --ip) IP_CONFIG="$2"; shift 2 ;;
        --gateway) GATEWAY="$2"; shift 2 ;;
        --disk-size) DISK_GIB="$2"; shift 2 ;;
        --cores) CORES="$2"; shift 2 ;;
        --memory) MEMORY_MIB="$2"; shift 2 ;;
        --swap) SWAP_MIB="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --update-channel) UPDATE_CHANNEL="$2"; shift 2 ;;
        --metadata-url) METADATA_URL="$2"; shift 2 ;;
        --metadata-key-file) METADATA_KEY_FILE="$2"; shift 2 ;;
        --downloads-host) DOWNLOADS_HOST="$2"; shift 2 ;;
        --series-host) SERIES_HOST="$2"; shift 2 ;;
        --movies-host) MOVIES_HOST="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "Run this script as root on the Proxmox host"
need_cmd pct
need_cmd pveam
need_cmd pvesm
need_cmd curl

[ -r "$UPDATE_AGENT_SCRIPT" ] || die "Missing installer companion: $UPDATE_AGENT_SCRIPT"
[ -r "$UPDATE_AGENT_SERVICE" ] || die "Missing installer companion: $UPDATE_AGENT_SERVICE"

[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid must be numeric"
[ -n "$STORAGE" ] || die "--storage is required"
[[ "$DISK_GIB" =~ ^[0-9]+$ ]] || die "--disk-size must be numeric"
[ "$DISK_GIB" -ge 16 ] || die "Hosted Metadata root disk must be at least 16 GiB"
[ -r "$METADATA_KEY_FILE" ] || die "--metadata-key-file must reference a readable file"
[ -n "$METADATA_URL" ] || die "--metadata-url cannot be empty"

case "$UPDATE_CHANNEL" in
    develop|stable) ;;
    *) die "--update-channel must be develop or stable" ;;
esac

UPDATE_IMAGE_REPOSITORY="${IMAGE%@*}"
UPDATE_IMAGE_REPOSITORY="${UPDATE_IMAGE_REPOSITORY%:*}"
case "$UPDATE_IMAGE_REPOSITORY" in
    ghcr.io/zemerdon/media-vision) ;;
    *) die "Unsupported Media Vision image repository: $UPDATE_IMAGE_REPOSITORY" ;;
esac

if pct status "$VMID" >/dev/null 2>&1; then
    die "VMID $VMID already exists; refusing to modify it"
fi
pvesm status -storage "$STORAGE" >/dev/null 2>&1 || die "Unknown Proxmox storage: $STORAGE"
pvesm status -storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Unknown template storage: $TEMPLATE_STORAGE"

for path in "$DOWNLOADS_HOST" "$SERIES_HOST" "$MOVIES_HOST"; do
    if [ -n "$path" ] && [ ! -d "$path" ]; then
        die "Host bind-mount path does not exist: $path"
    fi
done

echo "Locating Debian 13 LXC template..."
TEMPLATE_NAME="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '$1 ~ /debian-13-standard_/ {sub(/^.*vztmpl\//, "", $1); print $1}' | sort -V | tail -1)"
if [ -z "$TEMPLATE_NAME" ]; then
    pveam update >/dev/null
    TEMPLATE_NAME="$(pveam available --section system | awk '$2 ~ /^debian-13-standard_/ {print $2}' | sort -V | tail -1)"
    [ -n "$TEMPLATE_NAME" ] || die "No Debian 13 standard LXC template is available"
    echo "Downloading $TEMPLATE_NAME to $TEMPLATE_STORAGE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

NET0="name=eth0,bridge=${BRIDGE},ip=${IP_CONFIG}"
if [ "$IP_CONFIG" != "dhcp" ]; then
    [ -n "$GATEWAY" ] || die "--gateway is required for a static --ip"
    NET0="${NET0},gw=${GATEWAY}"
fi

echo "Creating Media Vision LXC $VMID ($DISK_GIB GiB root disk)..."
pct create "$VMID" "$TEMPLATE_REF" \
    --hostname "$HOSTNAME" \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1,keyctl=1 \
    --cores "$CORES" \
    --memory "$MEMORY_MIB" \
    --swap "$SWAP_MIB" \
    --rootfs "${STORAGE}:${DISK_GIB}" \
    --net0 "$NET0" \
    --onboot 1

mp=0
for spec in "$DOWNLOADS_HOST:/srv/media-vision/downloads" "$SERIES_HOST:/srv/media-vision/series" "$MOVIES_HOST:/srv/media-vision/movies"; do
    source_path="${spec%%:*}"
    target_path="${spec#*:}"
    if [ -n "$source_path" ]; then
        pct set "$VMID" "-mp${mp}" "${source_path},mp=${target_path}"
        mp=$((mp + 1))
    fi
done

pct start "$VMID"

echo "Waiting for network and apt inside the LXC..."
for attempt in $(seq 1 60); do
    if pct exec "$VMID" -- bash -lc 'getent hosts download.docker.com >/dev/null 2>&1 && apt-get update >/dev/null 2>&1'; then
        break
    fi
    [ "$attempt" -lt 60 ] || die "LXC network/apt did not become ready"
    sleep 2
done

echo "Installing Docker Engine..."
pct exec "$VMID" -- bash -lc 'set -euo pipefail
apt-get install -y ca-certificates curl gpg python3 >/dev/null
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
arch=$(dpkg --print-architecture)
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
apt-get update >/dev/null
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
systemctl enable --now docker >/dev/null'

pct exec "$VMID" -- bash -lc 'install -d -m 0755 /opt/media-vision /opt/media-vision/secrets /var/lib/media-vision/config /srv/media-vision/downloads /srv/media-vision/series /srv/media-vision/movies /usr/local/lib/media-vision
umask 077
od -An -N32 -tx1 /dev/urandom | tr -d " \n" > /opt/media-vision/secrets/update_agent_key
chmod 0600 /opt/media-vision/secrets/update_agent_key'

HOST_TMP="$(mktemp -d)"
trap 'rm -rf "$HOST_TMP"' EXIT

cat >"$HOST_TMP/compose.yml" <<'EOF'
services:
  media-vision:
    image: ${MEDIA_VISION_IMAGE}
    container_name: media-vision
    restart: unless-stopped
    network_mode: host
    environment:
      PUID: 1000
      PGID: 1000
      UMASK: "002"
      TZ: ${TZ:-Etc/UTC}
      MEDIA_VISION_UPDATE_AGENT_URL: http://127.0.0.1:18991/v1/update
      MEDIA_VISION_UPDATE_AGENT_KEY_FILE: /run/secrets/update_agent_key
      SERIESVISION_METADATA_API_URL: ${MEDIA_VISION_METADATA_API_URL}
      SERIESVISION_METADATA_API_KEY_FILE: /run/secrets/metadata_api_key
    secrets:
      - metadata_api_key
      - update_agent_key
    volumes:
      - /var/lib/media-vision/config:/config
      - /srv/media-vision/downloads:/downloads
      - /srv/media-vision/series:/media/series
      - /srv/media-vision/movies:/media/movies
    security_opt:
      - no-new-privileges:true
secrets:
  metadata_api_key:
    file: /opt/media-vision/secrets/metadata_api_key
  update_agent_key:
    file: /opt/media-vision/secrets/update_agent_key
EOF

cat >"$HOST_TMP/media-vision.env" <<EOF
MEDIA_VISION_IMAGE=${IMAGE}
MEDIA_VISION_METADATA_API_URL=${METADATA_URL}
TZ=Etc/UTC
EOF
chmod 0600 "$HOST_TMP/media-vision.env"

cat >"$HOST_TMP/update-agent.env" <<EOF
MEDIA_VISION_UPDATE_ALLOWED_IMAGE=${UPDATE_IMAGE_REPOSITORY}
EOF
chmod 0600 "$HOST_TMP/update-agent.env"

cat >"$HOST_TMP/config.xml" <<EOF
<Config>
  <Branch>${UPDATE_CHANNEL}</Branch>
</Config>
EOF
chmod 0644 "$HOST_TMP/config.xml"

pct push "$VMID" "$HOST_TMP/compose.yml" /opt/media-vision/compose.yml -perms 0644
pct push "$VMID" "$HOST_TMP/config.xml" /var/lib/media-vision/config/config.xml -perms 0644
pct push "$VMID" "$HOST_TMP/media-vision.env" /opt/media-vision/media-vision.env -perms 0600
pct push "$VMID" "$METADATA_KEY_FILE" /opt/media-vision/secrets/metadata_api_key -perms 0600
pct push "$VMID" "$HOST_TMP/update-agent.env" /etc/media-vision-update-agent.env -perms 0600
pct push "$VMID" "$UPDATE_AGENT_SCRIPT" /usr/local/lib/media-vision/update-agent.py -perms 0755
pct push "$VMID" "$UPDATE_AGENT_SERVICE" /etc/systemd/system/media-vision-update-agent.service -perms 0644

echo "Starting Media Vision container update agent..."
pct exec "$VMID" -- bash -lc 'systemctl daemon-reload
systemctl enable --now media-vision-update-agent.service >/dev/null
curl -fsS http://127.0.0.1:18991/health >/dev/null'

echo "Pulling Media Vision image and starting container..."
pct exec "$VMID" -- bash -lc 'cd /opt/media-vision && docker compose --env-file media-vision.env -f compose.yml pull && docker compose --env-file media-vision.env -f compose.yml up -d'

echo "Waiting for Media Vision health..."
for attempt in $(seq 1 60); do
    if pct exec "$VMID" -- curl -fsS http://127.0.0.1:8989/ping >/dev/null 2>&1; then
        break
    fi
    [ "$attempt" -lt 60 ] || die "Media Vision did not become healthy; LXC $VMID has been left intact for diagnostics"
    sleep 2
done

LXC_IP="$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')"
echo "Media Vision Hosted Metadata installation is healthy."
echo "LXC: $VMID"
echo "Image: $IMAGE"
echo "Web UI: http://${LXC_IP:-<lxc-ip>}:8989"
echo "Persistent config: /var/lib/media-vision/config inside the LXC"
echo "No IMDb dataset/index is stored in this LXC."
