#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/zemerdon/media-vision/main/installer"
RELEASE_IMAGE="${MEDIA_VISION_IMAGE:-ghcr.io/zemerdon/media-vision@sha256:77d77e06b1bcec050355d60fc7aaded704d37d0f86b6970812212a7b7f20f63c}"
UPDATE_CHANNEL="${MEDIA_VISION_UPDATE_CHANNEL:-develop}"
DEV_METADATA_URL="${MEDIA_VISION_METADATA_URL:-http://50.50.50.16:18992}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Run this command as root on the Proxmox host"

for cmd in curl pct pveam pvesh pvesm; do
    command -v "$cmd" >/dev/null 2>&1 || die "This must run on a Proxmox VE host (missing: $cmd)"
done

VMID="${MEDIA_VISION_VMID:-$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')}"
[ -n "$VMID" ] || die "Could not determine the next Proxmox VMID"

STORAGE="${MEDIA_VISION_STORAGE:-$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')}"
[ -n "$STORAGE" ] || die "Could not find active Proxmox storage supporting LXC root disks"

TEMPLATE_STORAGE="${MEDIA_VISION_TEMPLATE_STORAGE:-$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')}"
[ -n "$TEMPLATE_STORAGE" ] || die "Could not find active Proxmox storage supporting LXC templates"

BRIDGE="${MEDIA_VISION_BRIDGE:-vmbr0}"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist"

echo
echo "Media Vision public pre-release LXC installer"
echo "  VMID:       $VMID"
echo "  Storage:    $STORAGE"
echo "  Template:   $TEMPLATE_STORAGE"
echo "  Bridge:     $BRIDGE"
echo "  Image:      $RELEASE_IMAGE"
echo "  Channel:    $UPDATE_CHANNEL"
echo "  Root disk:  16 GiB"
echo

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

"$TMP/install-hosted.sh"     --vmid "$VMID"     --storage "$STORAGE"     --template-storage "$TEMPLATE_STORAGE"     --hostname media-vision     --bridge "$BRIDGE"     --ip dhcp     --image "$RELEASE_IMAGE"     --update-channel "$UPDATE_CHANNEL"     --metadata-url "$DEV_METADATA_URL"     --metadata-key-file "$TMP/metadata.key"
