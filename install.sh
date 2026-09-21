#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/zemerdon/media-vision/main/installer"
RELEASE_IMAGE="${MEDIA_VISION_IMAGE:-ghcr.io/zemerdon/media-vision@sha256:d4f128e5ebbebdb9da93e1d676379428fd089d0408e3323271647eefaf5c28c5}"
UPDATE_CHANNEL="${MEDIA_VISION_UPDATE_CHANNEL:-develop}"
DEFAULT_DISK_GIB=16
DEFAULT_CORES=2
DEFAULT_MEMORY_MIB=2048
DEFAULT_SWAP_MIB=512
DEFAULT_HOSTNAME=media-vision

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "Run this command as root on the Proxmox host"

for cmd in curl pct pveam pvesh pvesm ip; do
    command -v "$cmd" >/dev/null 2>&1 || die "This must run on a Proxmox VE host (missing: $cmd)"
done

DEFAULT_VMID="$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')"
[ -n "$DEFAULT_VMID" ] || die "Could not determine the next Proxmox VMID"

DEFAULT_STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
[ -n "$DEFAULT_STORAGE" ] || die "Could not find active Proxmox storage supporting LXC root disks"

DEFAULT_TEMPLATE_STORAGE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
[ -n "$DEFAULT_TEMPLATE_STORAGE" ] || die "Could not find active Proxmox storage supporting LXC templates"

DEFAULT_BRIDGE=vmbr0
if ! ip link show "$DEFAULT_BRIDGE" >/dev/null 2>&1; then
    DEFAULT_BRIDGE="$(ip -o link show type bridge 2>/dev/null | awk -F': ' 'NR==1 {sub(/@.*/, "", $2); print $2}')"
fi
[ -n "$DEFAULT_BRIDGE" ] || die "Could not find a Proxmox network bridge"

DEFAULT_TIMEZONE="Etc/UTC"
if command -v timedatectl >/dev/null 2>&1; then
    detected_tz="$(timedatectl show --value --property=Timezone 2>/dev/null || true)"
    [ -n "$detected_tz" ] && DEFAULT_TIMEZONE="$detected_tz"
fi

VMID="${MEDIA_VISION_VMID:-$DEFAULT_VMID}"
STORAGE="${MEDIA_VISION_STORAGE:-$DEFAULT_STORAGE}"
TEMPLATE_STORAGE="${MEDIA_VISION_TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}"
HOSTNAME="${MEDIA_VISION_HOSTNAME:-$DEFAULT_HOSTNAME}"
BRIDGE="${MEDIA_VISION_BRIDGE:-$DEFAULT_BRIDGE}"
IP_CONFIG="${MEDIA_VISION_IP:-dhcp}"
GATEWAY="${MEDIA_VISION_GATEWAY:-}"
DNS_SERVER="${MEDIA_VISION_DNS_SERVER:-}"
ROOT_SSH="${MEDIA_VISION_ROOT_SSH:-no}"
ROOT_PASSWORD=""
ROOT_PASSWORD_FILE="${MEDIA_VISION_ROOT_PASSWORD_FILE:-}"
DISK_GIB="${MEDIA_VISION_DISK_GIB:-$DEFAULT_DISK_GIB}"
CORES="${MEDIA_VISION_CORES:-$DEFAULT_CORES}"
MEMORY_MIB="${MEDIA_VISION_MEMORY_MIB:-$DEFAULT_MEMORY_MIB}"
SWAP_MIB="${MEDIA_VISION_SWAP_MIB:-$DEFAULT_SWAP_MIB}"
TIMEZONE="${MEDIA_VISION_TIMEZONE:-$DEFAULT_TIMEZONE}"
METADATA_URL="${MEDIA_VISION_METADATA_URL:-}"
KEY="${MEDIA_VISION_METADATA_KEY:-}"

VISUAL=0
if [ "${MEDIA_VISION_UNATTENDED:-0}" != "1" ] && [ -t 0 ] && [ -r /dev/tty ]; then
    command -v whiptail >/dev/null 2>&1 || die "whiptail is required for the interactive installer (install package: whiptail)"
    VISUAL=1
fi

visual_input() {
    local title="$1"
    local prompt="$2"
    local default="${3:-}"
    local value
    value="$(whiptail         --backtitle "Media Vision Proxmox Installer"         --title "$title"         --ok-button "Next" --cancel-button "Cancel"         --inputbox "$prompt" 12 70 "$default"         3>&1 1>&2 2>&3)" || exit 0
    printf '%s' "$value"
}

visual_password() {
    local title="$1"
    local prompt="$2"
    local value
    value="$(whiptail         --backtitle "Media Vision Proxmox Installer"         --title "$title"         --ok-button "Next" --cancel-button "Cancel"         --passwordbox "$prompt" 12 70         3>&1 1>&2 2>&3)" || exit 0
    printf '%s' "$value"
}

visual_storage_menu() {
    local title="$1"
    local content="$2"
    local selected="$3"
    local -a menu=()
    while read -r name type status total used available percent; do
        [ -n "$name" ] || continue
        [ "$status" = "active" ] || continue
        menu+=("$name" "$type")
    done < <(pvesm status --content "$content" 2>/dev/null | tail -n +2)

    [ "${#menu[@]}" -gt 0 ] || die "No active Proxmox storage supports $content"
    whiptail         --backtitle "Media Vision Proxmox Installer"         --title "$title"         --ok-button "Next" --cancel-button "Cancel"         --default-item "$selected"         --menu "Select storage:" 18 70 10         "${menu[@]}"         3>&1 1>&2 2>&3 || exit 0
}

visual_bridge_menu() {
    local selected="$1"
    local -a menu=()
    while read -r bridge; do
        [ -n "$bridge" ] || continue
        menu+=("$bridge" "Linux bridge")
    done < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{sub(/@.*/, "", $2); print $2}')

    if [ "${#menu[@]}" -eq 0 ]; then
        menu+=("$selected" "Network bridge")
    fi

    whiptail         --backtitle "Media Vision Proxmox Installer"         --title "NETWORK BRIDGE"         --ok-button "Next" --cancel-button "Cancel"         --default-item "$selected"         --menu "Select the LXC network bridge:" 18 70 10         "${menu[@]}"         3>&1 1>&2 2>&3 || exit 0
}

visual_metadata() {
    if [ -z "$METADATA_URL" ]; then
        METADATA_URL="$(visual_input "HOSTED METADATA" "Hosted Metadata API URL" "")"
    fi
    [ -n "$METADATA_URL" ] || die "Hosted metadata API URL cannot be empty"

    if [ -z "$KEY" ]; then
        KEY="$(visual_password "HOSTED METADATA KEY" "Enter the Hosted Metadata access key.

The key is hidden while typing.")"
    fi
    [ -n "$KEY" ] || die "Hosted metadata access key cannot be empty"
}

default_gateway_for_ipv4() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}$ ]]; then
        printf '%s.%s.%s.1' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    fi
}

visual_advanced() {
    VMID="$(visual_input "CONTAINER ID" "Set the Media Vision LXC VMID" "$VMID")"
    [[ "$VMID" =~ ^[0-9]+$ ]] || die "LXC VMID must be numeric"

    STORAGE="$(visual_storage_menu "ROOT STORAGE" rootdir "$STORAGE")"
    TEMPLATE_STORAGE="$(visual_storage_menu "TEMPLATE STORAGE" vztmpl "$TEMPLATE_STORAGE")"

    HOSTNAME="$(visual_input "HOSTNAME" "Set the LXC hostname" "$HOSTNAME")"
    [ -n "$HOSTNAME" ] || die "LXC hostname cannot be empty"

    DISK_GIB="$(visual_input "DISK SIZE" "Root disk size in GiB (minimum 16)" "$DISK_GIB")"
    [[ "$DISK_GIB" =~ ^[0-9]+$ ]] && [ "$DISK_GIB" -ge 16 ] || die "Root disk must be at least 16 GiB"

    CORES="$(visual_input "CPU CORES" "Number of CPU cores" "$CORES")"
    [[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "CPU cores must be a positive integer"

    MEMORY_MIB="$(visual_input "RAM" "RAM size in MiB" "$MEMORY_MIB")"
    [[ "$MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "RAM must be a positive integer"

    SWAP_MIB="$(visual_input "SWAP" "Swap size in MiB (0 disables swap)" "$SWAP_MIB")"
    [[ "$SWAP_MIB" =~ ^[0-9]+$ ]] || die "Swap must be numeric"

    BRIDGE="$(visual_bridge_menu "$BRIDGE")"
    ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist"

    network_mode="$(whiptail         --backtitle "Media Vision Proxmox Installer"         --title "IPv4 CONFIGURATION"         --ok-button "Next" --cancel-button "Cancel"         --menu "Select IPv4 address assignment:" 16 70 4         "dhcp" "Automatic (DHCP, recommended)"         "static" "Static (manual IP/CIDR and gateway)"         3>&1 1>&2 2>&3)" || exit 0

    case "$network_mode" in
        dhcp)
            IP_CONFIG=dhcp
            GATEWAY=""
            ;;
        static)
            static_default="$IP_CONFIG"
            [ "$static_default" = "dhcp" ] && static_default=""
            IP_CONFIG="$(visual_input "STATIC IPv4 ADDRESS" "Enter static IPv4 CIDR
Example: 192.168.1.50/24" "$static_default")"
            [ -n "$IP_CONFIG" ] || die "Static IPv4 CIDR cannot be empty"
            gateway_default="$GATEWAY"
            [ -n "$gateway_default" ] || gateway_default="$(default_gateway_for_ipv4 "$IP_CONFIG")"
            GATEWAY="$(visual_input "IPv4 GATEWAY" "Enter the IPv4 gateway" "$gateway_default")"
            [ -n "$GATEWAY" ] || die "IPv4 gateway cannot be empty"
            ;;
    esac

    DNS_SERVER="$(visual_input "DNS SERVER" "Enter a DNS server IP.

Leave blank to use the Proxmox/default DNS." "$DNS_SERVER")"

    if (whiptail         --backtitle "Media Vision Proxmox Installer"         --defaultno         --title "ROOT SSH ACCESS"         --yesno "Enable root SSH access using a password?" 11 62); then
        ROOT_SSH=yes
        ROOT_PASSWORD="$(visual_password "ROOT SSH PASSWORD" "Set the root password used for SSH.

The password is hidden while typing.")"
        [ -n "$ROOT_PASSWORD" ] || die "Root SSH password cannot be empty"
        ROOT_PASSWORD_CONFIRM="$(visual_password "CONFIRM ROOT SSH PASSWORD" "Enter the root SSH password again.")"
        [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ] || die "Root SSH passwords do not match"
        unset ROOT_PASSWORD_CONFIRM
    else
        ROOT_SSH=no
        ROOT_PASSWORD=""
    fi

    TIMEZONE="$(visual_input "TIMEZONE" "Container/application timezone" "$TIMEZONE")"
    [ -n "$TIMEZONE" ] || die "Timezone cannot be empty"
}

visual_confirm() {
    local network="$IP_CONFIG"
    [ -n "$GATEWAY" ] && network="$network  gateway $GATEWAY"

    local summary
    summary="Media Vision Hosted Metadata LXC

VMID:             $VMID
Hostname:         $HOSTNAME
Root storage:     $STORAGE
Template storage: $TEMPLATE_STORAGE
Disk:             $DISK_GIB GiB
CPU:              $CORES cores
RAM:              $MEMORY_MIB MiB
Swap:             $SWAP_MIB MiB
Bridge:           $BRIDGE
IPv4:             $network
DNS:              ${DNS_SERVER:-Proxmox/default}
Root SSH:         $ROOT_SSH
Timezone:         $TIMEZONE
Update channel:   $UPDATE_CHANNEL
Metadata API:     $METADATA_URL

The metadata access key is stored securely and is not shown here."

    whiptail         --backtitle "Media Vision Proxmox Installer"         --title "CONFIRM SETTINGS"         --ok-button "Create LXC" --cancel-button "Back"         --yesno "$summary" 28 76 || return 1
}

if [ "$VISUAL" -eq 1 ]; then
    while true; do
        choice="$(whiptail             --backtitle "Media Vision Proxmox Installer"             --title "Media Vision Options"             --ok-button "Select" --cancel-button "Exit Script"             --menu "Choose an installation mode:

Use TAB or Arrow keys to navigate, ENTER to select."             18 66 6             "1" "Default Install"             "2" "Advanced Install"             3>&1 1>&2 2>&3)" || exit 0

        case "$choice" in
            1)
                VMID="${MEDIA_VISION_VMID:-$DEFAULT_VMID}"
                STORAGE="${MEDIA_VISION_STORAGE:-$DEFAULT_STORAGE}"
                TEMPLATE_STORAGE="${MEDIA_VISION_TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}"
                HOSTNAME="${MEDIA_VISION_HOSTNAME:-$DEFAULT_HOSTNAME}"
                BRIDGE="${MEDIA_VISION_BRIDGE:-$DEFAULT_BRIDGE}"
                IP_CONFIG="${MEDIA_VISION_IP:-dhcp}"
                GATEWAY="${MEDIA_VISION_GATEWAY:-}"
                DNS_SERVER="${MEDIA_VISION_DNS_SERVER:-}"
                ROOT_SSH="${MEDIA_VISION_ROOT_SSH:-no}"
                ROOT_PASSWORD=""
                ROOT_PASSWORD_FILE="${MEDIA_VISION_ROOT_PASSWORD_FILE:-}"
                DISK_GIB="${MEDIA_VISION_DISK_GIB:-$DEFAULT_DISK_GIB}"
                CORES="${MEDIA_VISION_CORES:-$DEFAULT_CORES}"
                MEMORY_MIB="${MEDIA_VISION_MEMORY_MIB:-$DEFAULT_MEMORY_MIB}"
                SWAP_MIB="${MEDIA_VISION_SWAP_MIB:-$DEFAULT_SWAP_MIB}"
                TIMEZONE="${MEDIA_VISION_TIMEZONE:-$DEFAULT_TIMEZONE}"
                visual_metadata
                visual_confirm && break
                ;;
            2)
                visual_advanced
                visual_metadata
                visual_confirm && break
                ;;
        esac
    done
else
    [[ "$VMID" =~ ^[0-9]+$ ]] || die "LXC VMID must be numeric"
    [ -n "$STORAGE" ] || die "Root storage cannot be empty"
    [ -n "$TEMPLATE_STORAGE" ] || die "Template storage cannot be empty"
    [ -n "$HOSTNAME" ] || die "LXC hostname cannot be empty"
    [[ "$DISK_GIB" =~ ^[0-9]+$ ]] && [ "$DISK_GIB" -ge 16 ] || die "Root disk must be at least 16 GiB"
    [[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "CPU cores must be a positive integer"
    [[ "$MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die "RAM must be a positive integer"
    [[ "$SWAP_MIB" =~ ^[0-9]+$ ]] || die "Swap must be numeric"

    if [ "$IP_CONFIG" != "dhcp" ] && [ -z "$GATEWAY" ]; then
        GATEWAY="$(default_gateway_for_ipv4 "$IP_CONFIG")"
        [ -n "$GATEWAY" ] || die "MEDIA_VISION_GATEWAY is required with a static MEDIA_VISION_IP"
    fi

    case "$ROOT_SSH" in
        yes|no) ;;
        *) die "MEDIA_VISION_ROOT_SSH must be yes or no" ;;
    esac
    if [ "$ROOT_SSH" = "yes" ]; then
        [ -n "$ROOT_PASSWORD_FILE" ] || die "MEDIA_VISION_ROOT_PASSWORD_FILE is required when unattended root SSH is enabled"
        [ -r "$ROOT_PASSWORD_FILE" ] || die "MEDIA_VISION_ROOT_PASSWORD_FILE is not readable"
    fi

    [ -n "$METADATA_URL" ] || die "MEDIA_VISION_METADATA_URL is required for unattended installs"
    [ -n "$KEY" ] || die "MEDIA_VISION_METADATA_KEY is required for unattended installs"
fi

if [ "$IP_CONFIG" != "dhcp" ] && [ -z "$GATEWAY" ]; then
    GATEWAY="$(default_gateway_for_ipv4 "$IP_CONFIG")"
    [ -n "$GATEWAY" ] || die "A gateway is required for static IPv4"
fi

case "$ROOT_SSH" in
    yes|no) ;;
    *) die "Root SSH must be yes or no" ;;
esac
if [ "$ROOT_SSH" = "yes" ] && [ -z "$ROOT_PASSWORD" ]; then
    [ -n "$ROOT_PASSWORD_FILE" ] && [ -r "$ROOT_PASSWORD_FILE" ] || die "A readable root password file is required when root SSH is enabled non-interactively"
fi

pvesm status -storage "$STORAGE" >/dev/null 2>&1 || die "Unknown or inactive Proxmox storage: $STORAGE"
pvesm status -storage "$TEMPLATE_STORAGE" >/dev/null 2>&1 || die "Unknown or inactive template storage: $TEMPLATE_STORAGE"
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Network bridge $BRIDGE does not exist"

echo
echo "Media Vision public pre-release LXC installer"
echo "  VMID:       $VMID"
echo "  Storage:    $STORAGE"
echo "  Template:   $TEMPLATE_STORAGE"
echo "  Hostname:   $HOSTNAME"
echo "  Bridge:     $BRIDGE"
echo "  IPv4:       $IP_CONFIG"
[ -n "$GATEWAY" ] && echo "  Gateway:    $GATEWAY"
[ -n "$DNS_SERVER" ] && echo "  DNS:        $DNS_SERVER"
echo "  Root SSH:   $ROOT_SSH"
echo "  Disk:       $DISK_GIB GiB"
echo "  CPU:        $CORES"
echo "  RAM:        $MEMORY_MIB MiB"
echo "  Swap:       $SWAP_MIB MiB"
echo "  Timezone:   $TIMEZONE"
echo "  Image:      $RELEASE_IMAGE"
echo "  Channel:    $UPDATE_CHANNEL"
echo

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

if [ "$ROOT_SSH" = "yes" ]; then
    if [ -n "$ROOT_PASSWORD" ]; then
        printf '%s' "$ROOT_PASSWORD" > "$TMP/root-password"
        chmod 0600 "$TMP/root-password"
        ROOT_PASSWORD_FILE="$TMP/root-password"
        unset ROOT_PASSWORD
    fi
fi

INSTALL_ARGS=(
    --vmid "$VMID"
    --storage "$STORAGE"
    --template-storage "$TEMPLATE_STORAGE"
    --hostname "$HOSTNAME"
    --bridge "$BRIDGE"
    --ip "$IP_CONFIG"
    --root-ssh "$ROOT_SSH"
    --disk-size "$DISK_GIB"
    --cores "$CORES"
    --memory "$MEMORY_MIB"
    --swap "$SWAP_MIB"
    --timezone "$TIMEZONE"
    --image "$RELEASE_IMAGE"
    --update-channel "$UPDATE_CHANNEL"
    --metadata-url "$METADATA_URL"
    --metadata-key-file "$TMP/metadata.key"
)
[ -n "$GATEWAY" ] && INSTALL_ARGS+=(--gateway "$GATEWAY")
[ -n "$DNS_SERVER" ] && INSTALL_ARGS+=(--nameserver "$DNS_SERVER")
[ "$ROOT_SSH" = "yes" ] && INSTALL_ARGS+=(--root-password-file "$ROOT_PASSWORD_FILE")

"$TMP/install-hosted.sh" "${INSTALL_ARGS[@]}"
