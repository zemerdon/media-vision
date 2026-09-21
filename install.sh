#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/zemerdon/media-vision/main/installer"
RELEASE_IMAGE="${MEDIA_VISION_IMAGE:-ghcr.io/zemerdon/media-vision@sha256:d93f1fd7311b77d0a3f22c6f678689ef50220bedf18d81736f69a922198e75af}"
UPDATE_CHANNEL="${MEDIA_VISION_UPDATE_CHANNEL:-develop}"
METADATA_URL="${MEDIA_VISION_METADATA_URL:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Run this command as root on the Proxmox host"

for cmd in curl pct pveam pvesh pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "This must run on a Proxmox VE host (missing: $cmd)"
done

prompt_default() {
    local label="$1"
    local default="$2"
    local value=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
        printf '%s [%s]: ' "$label" "$default" >/dev/tty
        IFS= read -r value </dev/tty || true
    fi
    printf '%s' "${value:-$default}"
}

DEFAULT_VMID="$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')"
[ -n "$DEFAULT_VMID" ] || die "Could not determine the next Proxmox VMID"
VMID="${MEDIA_VISION_VMID:-}"
[ -n "$VMID" ] || VMID="$(prompt_default "LXC VMID" "$DEFAULT_VMID")"
[[ "$VMID" =~ ^[0-9]+$ ]] || die "LXC VMID must be numeric"

DEFAULT_STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
[ -n "$DEFAULT_STORAGE" ] || die "Could not find active Proxmox storage supporting LXC root disks"
if [ -t 0 ]; then
    echo "Available LXC root storages:"
    pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {printf "  %s (%s)\n", $1, $2}'
fi
STORAGE="${MEDIA_VISION_STORAGE:-}"
[ -n "$STORAGE" ] || STORAGE="$(prompt_default "Root storage" "$DEFAULT_STORAGE")"
pvesm status -storage "$STORAGE" >/dev/null 2>&1 || die "Unknown or inactive Proxmox storage: $STORAGE"

DEFAULT_TEMPLATE_STORAGE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
[ -n "$DEFAULT_TEMPLATE_STORAGE" ] || die "Could not find active Proxmox storage supporting LXC templates"
if [ -t 0 ]; then
    echo "Available template storages:"
    pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {printf "  %s (%s)\n", $1, $2}'
fi
TEMPLATE_STORAGE="${MEDIA_VISION_TEMPLATE_STORAGE:-}"
[ -n "$TEMPLATE_STORAGE" ] || TEMPLATE_STORAGE="$(prompt_default "Template storage" "$DEFAULT_TEMPLATE_STORAGE")"
pvesm status -storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Unknown or inactive template storage: $TEMPLATE_STORAGE"

HOSTNAME="${MEDIA_VISION_HOSTNAME:-}"
[ -n "$HOSTNAME" ] || HOSTNAME="$(prompt_default "LXC hostname" "media-vision")"
[ -n "$HOSTNAME" ] || die "LXC hostname cannot be empty"

DEFAULT_BRIDGE=vmbr0
if ! ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1; then
    DEFAULT_BRIDGE="$(ip -o link show type bridge 2>/dev/null | awk -F': ' 'NR==1 {sub(/@.*/, "", $2); print $2}')"
fi
[ -n "$DEFAULT_BRIDGE" ] || die "Could not find an active network bridge"
if [ -t 0 ]; then
    echo "Available bridges:"
    ip -o link show type bridge 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); printf "  %s\n", $2}'
fi
BRIDGE="${MEDIA_VISION_BRIDGE:-}"
[ -n "$BRIDGE" ] || BRIDGE="$(prompt_default "Network bridge" "$DEFAULT_BRIDGE")"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist"

IP_CONFIG="${MEDIA_VISION_IP:-}"
GATEWAY="${MEDIA_VISION_GATEWAY:-}"
if [ -z "$IP_CONFIG" ]; then
    NETWORK_MODE="$(prompt_default "IPv4 assignment (dhcp/static)" "dhcp")"
    case "${NETWORK_MODE,,}" in
        dhcp)
            IP_CONFIG=dhcp
            GATEWAY=""
            ;;
        static)
            IP_CONFIG="$(prompt_default "Static IPv4 CIDR (example 192.168.1.50/24)" "")"
            [ -n "$IP_CONFIG" ] || die "Static IPv4 CIDR cannot be empty"
            GATEWAY="$(prompt_default "IPv4 gateway" "")"
            [ -n "$GATEWAY" ] || die "IPv4 gateway cannot be empty for static networking"
            ;;
        *) die "IPv4 assignment must be dhcp or static" ;;
    esac
elif [ "$IP_CONFIG" != "dhcp" ] && [ -z "$GATEWAY" ]; then
    GATEWAY="$(prompt_default "IPv4 gateway" "")"
    [ -n "$GATEWAY" ] || die "MEDIA_VISION_GATEWAY is required with a static MEDIA_VISION_IP"
fi

echo
echo "Media Vision public pre-release LXC installer"
echo "  VMID:       $VMID"
echo "  Storage:    $STORAGE"
echo "  Template:   $TEMPLATE_STORAGE"
echo "  Hostname:   $HOSTNAME"
echo "  Bridge:     $BRIDGE"
echo "  IPv4:       $IP_CONFIG"
[ -n "$GATEWAY" ] && echo "  Gateway:    $GATEWAY"
echo "  Image:      $RELEASE_IMAGE"
echo "  Channel:    $UPDATE_CHANNEL"
echo "  Root disk:  16 GiB"
echo

if [ -z "$METADATA_URL" ]; then
    if [ ! -r /dev/tty ]; then
        die "No terminal is available for the hosted metadata API URL prompt"
    fi
    read -r -p "Hosted metadata API URL: " METADATA_URL </dev/tty
fi

[ -n "$METADATA_URL" ] || die "Hosted metadata API URL cannot be empty"

KEY="${MEDIA_VISION_METADATA_KEY:-}"
if [ -z "$KEY" ]; then
    if [ ! -r /dev/tty ]; then
        die "No terminal is available for the hosted metadata key prompt"
    fi
    read -r -s -p "Hosted metadata access key: " KEY </dev/tty
    echo >/dev/tty
fi

[ -n "$KEY" ] || die "Hosted metadata access key cannot be empty"

TMP="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT
chmod 0700 "$TMP"

for file in install-hosted.sh update-agent.py media-vision-update-agent.service; do
    curl -fsSL "$RAW_BASE/$file" -o "$TMP/$file" || die "Could not download $file"
done

chmod 0755 "$TMP/install-hosted.sh" "$TMP/update-agent.py"
chmod 0644 "$TMP/media-vision-update-agent.service"

umask 077
printf '%s' "$KEY" > "$TMP/metadata.key"
unset KEY MEDIA_VISION_METADATA_KEY

INSTALL_ARGS=(
    --vmid "$VMID"
    --storage "$STORAGE"
    --template-storage "$TEMPLATE_STORAGE"
    --hostname "$HOSTNAME"
    --bridge "$BRIDGE"
    --ip "$IP_CONFIG"
    --image "$RELEASE_IMAGE"
    --update-channel "$UPDATE_CHANNEL"
    --metadata-url "$METADATA_URL"
    --metadata-key-file "$TMP/metadata.key"
)
[ -n "$GATEWAY" ] && INSTALL_ARGS+=(--gateway "$GATEWAY")

"$TMP/install-hosted.sh" "${INSTALL_ARGS[@]}"
