#!/usr/bin/env bash
set -euo pipefail

MODE=''
CHECKPOINT='1'
CHECK_NEEDS_APPLY=0
NETWORK_TRANSACTION_ID=''
CONFIRM_NETWORK_TRANSACTION_ID=''
CLEANUP_CLIENT=0
readonly POWERSEVEN_BOOTSTRAP_VERSION='7'
readonly POWERSEVEN_BOOTSTRAP_CAPABILITIES='1,2,3'
readonly MIN_FREE_BYTES=$((1024 * 1024))
readonly FS_MARGIN_BYTES=$((1024 * 1024 * 1024))
readonly UNDERLAY_NETWORK='192.168.214.0/24'
readonly UNDERLAY_ADDRESS='192.168.214.14/24'
readonly UNDERLAY_GATEWAY='192.168.214.2'
readonly UNDERLAY_DNS='192.168.214.13'
readonly ADMIN_NETWORK='10.99.0.0/24'
readonly ADMIN_SERVER_ADDRESS='10.99.0.1/24'
readonly ADMIN_CLIENT_ADDRESS='10.99.0.2/32'
readonly ADMIN_CLIENT_NAME='powerseven-admin-laptop'
readonly WG_INTERFACE='wg-admin'
readonly WG_PORT='51820'
readonly WG_CONFIG='/etc/wireguard/wg-admin.conf'
readonly WG_SERVER_KEY='/etc/wireguard/powerseven-wg-admin-server.key'
readonly WG_SERVER_PUB='/etc/wireguard/powerseven-wg-admin-server.pub'
readonly WG_CLIENT_STATE_DIR='/var/lib/powerseven/admin-vpn/clients'
readonly WG_CLIENT_STATE='/var/lib/powerseven/admin-vpn/clients/powerseven-admin-laptop.pub'
readonly WG_CLIENT_EXPORT='/tmp/powerseven-admin-laptop.conf'
readonly NETWORK_STATE_DIR='/var/lib/powerseven/network'
readonly NETWORK_PENDING_DIR='/run/powerseven'
readonly NETWORK_LOCK_FILE='/run/powerseven/network.lock'
readonly NETWORK_READY_TIMEOUT_SECONDS=45
readonly NETWORK_READY_INTERVAL_SECONDS=2

usage() {
    cat <<'EOF'
Usage: bootstrap.sh --check|--apply [--checkpoint N]

Metadata:
  --version       print the bootstrap contract version
  --capabilities  print supported checkpoints
  --protocol      print version and capabilities for the runner

Implemented checkpoints:
  1  detect and expand the mounted root LVM using VG space already available
  2  configure the two-NIC local network with a rollback guard
  3  configure the WireGuard administrative VPN and first client staging

Future checkpoints are intentionally not implemented yet.
EOF
}

if [[ "$#" -eq 1 && "$1" == '--version' ]]; then
    printf 'powerseven-bootstrap %s\n' "$POWERSEVEN_BOOTSTRAP_VERSION"
    exit 0
fi
if [[ "$#" -eq 1 && "$1" == '--capabilities' ]]; then
    printf 'checkpoints=%s\n' "$POWERSEVEN_BOOTSTRAP_CAPABILITIES"
    exit 0
fi
if [[ "$#" -eq 1 && "$1" == '--protocol' ]]; then
    printf 'powerseven-bootstrap %s\ncheckpoints=%s\n' "$POWERSEVEN_BOOTSTRAP_VERSION" "$POWERSEVEN_BOOTSTRAP_CAPABILITIES"
    exit 0
fi

report() {
    printf '%s: %s: %s\n' "$1" "$2" "$3"
}

fail_apply_or_skip_check() {
    local label="$1" detail="$2"
    if [[ "$MODE" == 'apply' ]]; then
        report FAIL "$label" "$detail"
        return 1
    fi
    report SKIP "$label" "$detail"
    return 0
}

require_commands() {
    local missing=0 command_name status
    for command_name in "$@"; do
        if ! command -v "$command_name" >/dev/null 2>&1; then
            if [[ "$MODE" == 'apply' ]]; then status='FAIL'; else status='SKIP'; fi
            report "$status" "command:$command_name" 'required command is unavailable'
            missing=1
        fi
    done
    return "$missing"
}

trim() {
    awk '{$1=$1; print}'
}

format_gib() {
    awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'
}

numeric_value() {
    awk 'NF { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit }'
}

detect_root() {
    ROOT_TARGET=$(findmnt -no TARGET -T /)
    ROOT_SOURCE=$(findmnt -no SOURCE -T /)
    ROOT_FSTYPE=$(findmnt -no FSTYPE -T /)
    ROOT_DEVICE=$(readlink -f "$ROOT_SOURCE")
    ROOT_FS_BYTES=$(df -B1 --output=size / | tail -n 1 | numeric_value)

    [[ "$ROOT_TARGET" == '/' ]] || return 1
    [[ -n "$ROOT_SOURCE" && -n "$ROOT_DEVICE" && "$ROOT_FS_BYTES" =~ ^[0-9]+$ ]]
}

detect_lvm() {
    local lvs_output candidate_vg candidate_lv candidate_path candidate_real
    LVM_CANDIDATE_COUNT=0
    LVM_MATCHES=()

    # Enumerate all LVs, then compare canonical device nodes. LVM may expose
    # the same LV as /dev/mapper/... or /dev/<vg>/<lv>.
    lvs_output=$(lvs --noheadings --separator '|' --options vg_name,lv_name,lv_path 2>/dev/null || true)
    while IFS='|' read -r candidate_vg candidate_lv candidate_path; do
        candidate_vg=$(printf '%s' "$candidate_vg" | trim)
        candidate_lv=$(printf '%s' "$candidate_lv" | trim)
        candidate_path=$(printf '%s' "$candidate_path" | trim)
        [[ -n "$candidate_vg" && -n "$candidate_lv" && -n "$candidate_path" ]] || continue
        LVM_CANDIDATE_COUNT=$((LVM_CANDIDATE_COUNT + 1))
        candidate_real=$(readlink -f "$candidate_path" 2>/dev/null || true)
        if [[ -n "$candidate_real" && "$candidate_real" == "$ROOT_DEVICE" ]]; then
            LVM_MATCHES+=("$candidate_vg|$candidate_lv|$candidate_path|$candidate_real")
        fi
    done <<< "$lvs_output"

    LVM_MATCH_COUNT=${#LVM_MATCHES[@]}
    if [[ "$LVM_MATCH_COUNT" -ne 1 ]]; then
        return 1
    fi

    IFS='|' read -r VG_NAME LV_NAME LV_PATH LV_DEVICE <<< "${LVM_MATCHES[0]}"
    [[ -n "$VG_NAME" && -n "$LV_NAME" && -n "$LV_PATH" && "$LV_DEVICE" == "$ROOT_DEVICE" ]]
}

read_lvm_sizes() {
    if ! VG_FREE_BYTES=$(vgs --noheadings --nosuffix --units b --options vg_free "$VG_NAME" | numeric_value); then
        return 1
    fi
    if ! LV_BYTES=$(lvs --noheadings --nosuffix --units b --options lv_size "$LV_PATH" | numeric_value); then
        return 1
    fi
    [[ "$VG_FREE_BYTES" =~ ^[0-9]+$ && "$LV_BYTES" =~ ^[0-9]+$ ]]
}

report_disk_layout() {
    local pv_output pv_count pv pv_real ancestor_output ancestor_count
    local pv_name pv_type parent_name disk disk_real disk_type disk_bytes pv_bytes
    local pv_geometry pv_start_bytes pv_size_bytes pv_end_bytes
    if ! command -v blockdev >/dev/null 2>&1; then
        report WARN disk-layout 'blockdev unavailable; future disk/partition gap not evaluated'
        return 0
    fi

    pv_output=$(pvs --noheadings --separator '|' --options pv_name,vg_name 2>/dev/null || true)
    mapfile -t PV_NAMES < <(printf '%s\n' "$pv_output" | awk -F'|' -v vg="$VG_NAME" '$2 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); if ($2 == vg && $1) print $1 }')
    pv_count=${#PV_NAMES[@]}
    if [[ "$pv_count" -eq 0 ]]; then
        report WARN disk-layout "no PV found for VG $VG_NAME; future disk growth not evaluated"
        return 0
    fi
    if [[ "$pv_count" -gt 1 ]]; then
        report WARN disk-layout "VG $VG_NAME has $pv_count PVs; future partition/PV growth needs separate review"
        return 0
    fi

    pv=${PV_NAMES[0]}
    if ! pv_real=$(readlink -f "$pv"); then
        report WARN disk-layout "could not canonicalize PV path $pv"
        return 0
    fi
    if [[ ! -b "$pv_real" ]]; then
        report WARN disk-layout "PV path is not one block device: $pv_real"
        return 0
    fi
    report PASS root-pv "$pv_real"

    if ! ancestor_output=$(lsblk -dnpo NAME,TYPE,PKNAME "$pv_real"); then
        report WARN disk-layout "could not inspect PV ancestor for $pv_real"
        return 0
    fi
    mapfile -t PV_ANCESTOR_ROWS < <(printf '%s\n' "$ancestor_output" | awk 'NF >= 2 { print }')
    ancestor_count=${#PV_ANCESTOR_ROWS[@]}
    if [[ "$ancestor_count" -ne 1 ]]; then
        report WARN disk-layout "PV ancestor is not unique for $pv_real (rows=$ancestor_count)"
        return 0
    fi

    read -r pv_name pv_type parent_name <<< "${PV_ANCESTOR_ROWS[0]}"
    if [[ "$pv_name" != "$pv_real" ]]; then
        report WARN disk-layout "lsblk returned a different PV path: $pv_name"
        return 0
    fi

    if [[ -z "$parent_name" && "$pv_type" == 'disk' ]]; then
        disk="$pv_real"
    elif [[ -n "$parent_name" && "$pv_type" == 'part' ]]; then
        if [[ "$parent_name" == /dev/* ]]; then
            disk="$parent_name"
        else
            disk="/dev/$parent_name"
        fi
    else
        report WARN disk-layout "unsupported or ambiguous PV ancestor: type=$pv_type parent=$parent_name"
        return 0
    fi
    if ! disk_real=$(readlink -f "$disk"); then
        report WARN disk-layout "could not canonicalize physical disk path $disk"
        return 0
    fi
    if [[ ! -b "$disk_real" ]]; then
        report WARN disk-layout "physical disk path is not one block device: $disk_real"
        return 0
    fi
    if ! disk_type=$(lsblk -dnro TYPE "$disk_real" | trim) || [[ "$disk_type" != 'disk' ]]; then
        report WARN disk-layout "physical disk ancestor is not TYPE=disk: $disk_real (type=$disk_type)"
        return 0
    fi
    report PASS root-disk "$disk_real"

    if ! disk_bytes=$(lsblk -bndo SIZE "$disk_real" | numeric_value); then
        report WARN disk-layout "could not read size for disk $disk_real"
        return 0
    fi
    if ! pv_bytes=$(blockdev --getsize64 "$pv_real"); then
        report WARN disk-layout "could not read size for PV $pv_real"
        return 0
    fi
    if [[ ! "$disk_bytes" =~ ^[0-9]+$ || ! "$pv_bytes" =~ ^[0-9]+$ ]]; then
        report WARN disk-layout "could not compare $disk_real with $pv_real"
    else
        report PASS disk-layout "disk=$(format_gib "$disk_bytes"); PV partition=$(format_gib "$pv_bytes")"
        if [[ "$pv_type" == 'disk' ]]; then
            report PASS disk-growth 'PV partition already reaches disk end'
        elif ! pv_geometry=$(lsblk -dnbo START,SIZE "$pv_real"); then
            report WARN disk-growth "could not read partition geometry for $pv_real"
        else
            read -r pv_start_bytes pv_size_bytes <<< "$pv_geometry"
            if [[ ! "$pv_start_bytes" =~ ^[0-9]+$ || ! "$pv_size_bytes" =~ ^[0-9]+$ ]]; then
                report WARN disk-growth "could not parse partition geometry for $pv_real"
            else
                pv_end_bytes=$((pv_start_bytes + pv_size_bytes))
                if (( pv_end_bytes + MIN_FREE_BYTES < disk_bytes )); then
                    report WARN disk-growth "unpartitioned space remains after $pv_real; growpart/pvresize is a separate future checkpoint"
                else
                    report PASS disk-growth 'PV partition already reaches disk end'
                fi
            fi
        fi
    fi
}

verify_root_mount() {
    local current_target current_source current_device
    current_target=$(findmnt -no TARGET -T /)
    current_source=$(findmnt -no SOURCE -T /)
    current_device=$(readlink -f "$current_source")
    [[ "$current_target" == '/' && "$current_device" == "$LV_DEVICE" ]]
}

storage_checkpoint() {
    local before_lv after_lv before_fs after_fs

    if ! require_commands findmnt df readlink awk lvs vgs pvs lsblk; then
        if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
    fi
    if ! detect_root; then
        fail_apply_or_skip_check root-device 'could not determine a unique mounted root filesystem'
        if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
    fi
    report PASS root-device "$ROOT_SOURCE"
    report PASS root-canonical "$ROOT_DEVICE"
    report PASS root-filesystem "mount=/; filesystem=$ROOT_FSTYPE; size=$(format_gib "$ROOT_FS_BYTES")"

    if ! detect_lvm; then
        if [[ "$LVM_MATCH_COUNT" -eq 0 ]]; then
            detail="no LV canonicalizes to root device $ROOT_DEVICE (candidates=$LVM_CANDIDATE_COUNT)"
        else
            detail="$LVM_MATCH_COUNT LVs canonicalize to root device $ROOT_DEVICE; refusing ambiguous match"
        fi
        fail_apply_or_skip_check root-lvm "$detail"
        if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
    fi
    report PASS root-lvm "$VG_NAME/$LV_NAME"
    report PASS root-lv-path "$LV_PATH"

    case "$ROOT_FSTYPE" in
        ext2|ext3|ext4|xfs) ;;
        *)
            fail_apply_or_skip_check filesystem-resize "unsupported root filesystem: $ROOT_FSTYPE"
            if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
            ;;
    esac

    if ! read_lvm_sizes; then
        fail_apply_or_skip_check lvm-size "could not read VG free space or LV size for $VG_NAME/$LV_NAME"
        if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
    fi
    report PASS root-size "LV=$(format_gib "$LV_BYTES"); filesystem=$(format_gib "$ROOT_FS_BYTES"); VG free=$(format_gib "$VG_FREE_BYTES")"
    report PASS vg-free "$VG_NAME: $(format_gib "$VG_FREE_BYTES") available"
    report_disk_layout

    if (( VG_FREE_BYTES <= MIN_FREE_BYTES )); then
        if (( ROOT_FS_BYTES + FS_MARGIN_BYTES < LV_BYTES )); then
            fail_apply_or_skip_check root-filesystem 'filesystem is smaller than LV; automatic repair is not implemented'
            if [[ "$MODE" == 'apply' ]]; then return 1; else return 0; fi
        fi
        report PASS root-expand 'root filesystem already consumes available VG space'
        return 0
    fi

    report MISSING root-expand "root LV uses $(format_gib "$LV_BYTES"); VG has $(format_gib "$VG_FREE_BYTES") free; LV can be expanded"
    if [[ "$MODE" == 'check' ]]; then
        CHECK_NEEDS_APPLY=1
        return 0
    fi

    if ! require_commands lvextend; then
        return 1
    fi
    before_lv=$LV_BYTES
    before_fs=$ROOT_FS_BYTES
    if ! lvextend -l +100%FREE -r "$LV_PATH"; then
        report FAIL root-expand "lvextend failed for $LV_PATH"
        return 1
    fi
    if ! read_lvm_sizes; then
        report FAIL root-expand 'could not re-read LVM sizes after lvextend'
        return 1
    fi
    after_lv=$LV_BYTES
    if ! after_fs=$(df -B1 --output=size / | tail -n 1 | numeric_value); then
        report FAIL root-filesystem 'could not re-read filesystem size after lvextend'
        return 1
    fi
    if (( after_lv <= before_lv )); then
        report FAIL root-expand "LV did not increase: $(format_gib "$before_lv") -> $(format_gib "$after_lv")"
        return 1
    fi
    if (( after_fs <= before_fs )); then
        report FAIL root-filesystem "filesystem did not increase: $(format_gib "$before_fs") -> $(format_gib "$after_fs")"
        return 1
    fi
    if ! verify_root_mount; then
        report FAIL root-mount 'root is no longer mounted from the detected LV'
        return 1
    fi
    report PASS root-expand "LV $(format_gib "$before_lv") -> $(format_gib "$after_lv")"
    report PASS root-filesystem "resized successfully to $(format_gib "$after_fs")"
}

get_interface_mac() {
    ip -o link show dev "$1" | awk -F'link/ether ' 'NF > 1 { print $2; exit }' | awk '{ print $1 }'
}

get_interface_ipv4() {
    ip -o -4 addr show dev "$1" scope global | awk 'NF { print $4; exit }'
}

get_interface_link_state() {
    local operstate carrier
    operstate=$(cat "/sys/class/net/$1/operstate" 2>/dev/null || printf 'unknown')
    carrier=$(cat "/sys/class/net/$1/carrier" 2>/dev/null || printf 'unknown')
    case "$carrier" in
        1) carrier='up' ;;
        0) carrier='down' ;;
    esac
    printf 'state=%s carrier=%s' "$operstate" "$carrier"
}

acquire_network_lock() {
    install -d -m 0750 "$NETWORK_PENDING_DIR"
    exec 9>"$NETWORK_LOCK_FILE"
    flock -x 9
}

release_network_lock() {
    flock -u 9 2>/dev/null || true
    exec 9>&-
}

stop_network_rollback_unit() {
    local unit="powerseven-netplan-rollback-$1"
    systemctl stop "$unit.timer" "$unit.service" 2>/dev/null || true
    systemctl reset-failed "$unit.timer" "$unit.service" 2>/dev/null || true
}

cancel_pending_network_transactions() {
    local unit pending_backup
    while read -r unit _; do
        [[ -n "$unit" ]] || continue
        systemctl stop "$unit" 2>/dev/null || true
    done < <(systemctl list-units --all --no-legend --plain 'powerseven-netplan-rollback-*' 2>/dev/null || true)

    acquire_network_lock
    pending_backup=$(cat "$NETWORK_STATE_DIR/pending-backup" 2>/dev/null || true)
    rm -f "$NETWORK_PENDING_DIR"/netplan-pending-* \
        "$NETWORK_PENDING_DIR"/netplan-running-* \
        "$NETWORK_PENDING_DIR"/netplan-rollback-*
    rm -f "$NETWORK_STATE_DIR/pending-token" "$NETWORK_STATE_DIR/pending-backup"
    if [[ "$pending_backup" == "$NETWORK_STATE_DIR/backups/"* ]]; then
        rm -rf "$pending_backup"
    fi
    release_network_lock
}

netplan_persistence_is_valid() {
    local file='/etc/netplan/99-powerseven.yaml' vmnet_mac bridged_mac metadata
    [[ -f "$file" ]] || return 1
    metadata=$(stat -c '%U:%G:%a' "$file" 2>/dev/null || true)
    [[ "$metadata" == 'root:root:600' ]] || return 1
    vmnet_mac=$(get_interface_mac "$VMNET8_IF")
    bridged_mac=$(get_interface_mac "$BRIDGED_IF")
    [[ "$vmnet_mac" =~ ^[0-9a-fA-F:]{17}$ && "$bridged_mac" =~ ^[0-9a-fA-F:]{17}$ ]] || return 1
    netplan_block_contains() {
        local block="$1" expected="$2"
        awk -v block="    $block:" -v expected="$expected" '
            $0 == block { in_block=1; next }
            in_block && $0 ~ /^    [^ ]/ { in_block=0 }
            in_block && index($0, expected) { found=1 }
            END { exit !found }
        ' "$file"
    }
    netplan_block_contains powerseven-underlay "match: {macaddress: $vmnet_mac}" || return 1
    netplan_block_contains powerseven-underlay 'addresses: [192.168.214.14/24]' || return 1
    netplan_block_contains powerseven-underlay 'via: 192.168.214.2' || return 1
    netplan_block_contains powerseven-underlay 'addresses: [192.168.214.13]' || return 1
    netplan_block_contains powerseven-bridged "match: {macaddress: $bridged_mac}" || return 1
    netplan_block_contains powerseven-bridged 'dhcp4: true' || return 1
    netplan_block_contains powerseven-bridged 'use-routes: false' || return 1
    netplan_block_contains powerseven-bridged 'use-dns: false' || return 1
    netplan generate >/dev/null 2>&1
}

validate_netplan_persistence() {
    if ! netplan_persistence_is_valid; then
        report FAIL network-persistence '99-powerseven.yaml is missing, invalid, mismatched or netplan generate failed'
        return 1
    fi
    report PASS network-persistence '99-powerseven.yaml is root:root 600, MAC-matched and netplan generate passed'
}

detect_network_interfaces() {
    local name address interface_type
    local -a ethernet_candidates=() underlay_candidates=() bridged_candidates=()

    VMNET8_IF=''
    VMNET8_ADDRESS=''
    BRIDGED_IF=''
    BRIDGED_ADDRESS='none'

    while read -r _ name _; do
        name=${name%:}
        name=${name%%@*}
        [[ -n "$name" && -r "/sys/class/net/$name/type" ]] || continue
        case "$name" in
            lo|docker*|br*|veth*|virbr*|wg*|tun*) continue ;;
        esac
        interface_type=$(cat "/sys/class/net/$name/type" 2>/dev/null || true)
        [[ "$interface_type" == '1' ]] || continue
        [[ -n "$(get_interface_mac "$name")" ]] || continue
        ethernet_candidates+=("$name")
    done < <(ip -o link show)

    for name in "${ethernet_candidates[@]}"; do
        address=$(ip -o -4 addr show dev "$name" scope global | awk '$4 ~ /^192\.168\.214\.[0-9]+\/24$/ { print $4; exit }')
        [[ -n "$address" ]] && underlay_candidates+=("$name|$address")
    done

    if [[ "${#underlay_candidates[@]}" -eq 1 ]]; then
        IFS='|' read -r VMNET8_IF VMNET8_ADDRESS <<< "${underlay_candidates[0]}"
    fi

    for name in "${ethernet_candidates[@]}"; do
        [[ "$name" == "$VMNET8_IF" ]] && continue
        address=$(get_interface_ipv4 "$name")
        bridged_candidates+=("$name|${address:-none}")
    done

    if [[ "${#bridged_candidates[@]}" -eq 1 ]]; then
        IFS='|' read -r BRIDGED_IF BRIDGED_ADDRESS <<< "${bridged_candidates[0]}"
    fi

    [[ "${#underlay_candidates[@]}" -eq 1 && "${#bridged_candidates[@]}" -eq 1 ]]
}

report_network_state() {
    local default_routes bridge_defaults dns_status
    report PASS network-underlay "interface=$VMNET8_IF address=$VMNET8_ADDRESS mac=$(get_interface_mac "$VMNET8_IF") $(get_interface_link_state "$VMNET8_IF")"
    report PASS network-bridged "interface=$BRIDGED_IF address=$BRIDGED_ADDRESS mac=$(get_interface_mac "$BRIDGED_IF") $(get_interface_link_state "$BRIDGED_IF")"
    default_routes=$(ip -4 route show default)
    if [[ "$(printf '%s\n' "$default_routes" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ]] &&
       grep -Fq "default via $UNDERLAY_GATEWAY dev $VMNET8_IF" <<< "$default_routes"; then
        report PASS default-route "via $UNDERLAY_GATEWAY dev $VMNET8_IF"
    else
        report FAIL default-route 'expected exactly one default route via 192.168.214.2 on VMnet8'
        return 1
    fi
    if ip -4 route show default dev "$BRIDGED_IF" | grep -q .; then
        report FAIL bridged-default-route 'bridged NIC has an unexpected default route'
        return 1
    fi
    if ! networkctl is-managed "$VMNET8_IF" >/dev/null 2>&1 ||
       ! networkctl is-managed "$BRIDGED_IF" >/dev/null 2>&1; then
        report FAIL networkd "systemd-networkd does not manage $VMNET8_IF and $BRIDGED_IF"
        return 1
    fi
    report PASS networkd "managed=$VMNET8_IF,$BRIDGED_IF"
    if command -v resolvectl >/dev/null 2>&1; then
        dns_status=$(resolvectl dns "$VMNET8_IF" 2>/dev/null || true)
        if grep -Fq "$UNDERLAY_DNS" <<< "$dns_status"; then
            report PASS dns "$UNDERLAY_DNS on $VMNET8_IF"
        else
            report FAIL dns "expected $UNDERLAY_DNS on $VMNET8_IF"
            return 1
        fi
    else
        report FAIL dns 'resolvectl is unavailable; DNS binding cannot be verified safely'
        return 1
    fi
    validate_netplan_persistence
}

verify_network_state() {
    local missing
    missing=$(network_state_missing)
    [[ -z "$missing" ]] || return 1
    report_network_state
}

network_state_missing() {
    local missing='' underlay_address bridge_address bridge_prefix default_routes dns_status bridged_dns
    local operstate carrier
    underlay_address=$(ip -o -4 addr show dev "$VMNET8_IF" scope global 2>/dev/null | awk '$4 == "192.168.214.14/24" { print $4; exit }' || true)
    [[ "$underlay_address" == "$UNDERLAY_ADDRESS" ]] || missing+='underlay static pending; '

    default_routes=$(ip -4 route show default 2>/dev/null || true)
    if [[ "$(printf '%s\n' "$default_routes" | awk 'NF { count++ } END { print count + 0 }')" -ne 1 ]] ||
       ! grep -Fq "default via $UNDERLAY_GATEWAY dev $VMNET8_IF" <<< "$default_routes"; then
        missing+='default route pending; '
    fi

    operstate=$(cat "/sys/class/net/$BRIDGED_IF/operstate" 2>/dev/null || printf 'unknown')
    carrier=$(cat "/sys/class/net/$BRIDGED_IF/carrier" 2>/dev/null || printf 'unknown')
    [[ "$operstate" == 'up' && "$carrier" == '1' ]] || missing+='bridged link/carrier pending; '

    bridge_address=$(ip -o -4 addr show dev "$BRIDGED_IF" scope global 2>/dev/null | awk 'NF { print $4; exit }' || true)
    bridge_prefix=${bridge_address#*/}
    [[ -n "$bridge_address" && "$bridge_prefix" =~ ^[0-9]+$ ]] || missing+='bridged DHCP pending; '

    if ip -4 route show default dev "$BRIDGED_IF" 2>/dev/null | grep -q .; then
        missing+='bridged default route present; '
    fi

    networkctl is-managed "$VMNET8_IF" >/dev/null 2>&1 || missing+='underlay networkd unmanaged; '
    networkctl is-managed "$BRIDGED_IF" >/dev/null 2>&1 || missing+='bridged networkd unmanaged; '

    if command -v resolvectl >/dev/null 2>&1; then
        dns_status=$(resolvectl dns "$VMNET8_IF" 2>/dev/null || true)
        grep -Fq "$UNDERLAY_DNS" <<< "$dns_status" || missing+='underlay DNS pending; '
        bridged_dns=$(resolvectl dns "$BRIDGED_IF" 2>/dev/null || true)
        if grep -Eq 'DNS Servers:|DNS Domain:' <<< "$bridged_dns"; then
            missing+='bridged DNS present; '
        fi
    else
        missing+='underlay DNS pending; '
    fi
    netplan_persistence_is_valid || missing+='persistent Netplan pending; '
    printf '%s' "${missing%; }"
}

wait_for_network_state() {
    local elapsed=0 missing
    while (( elapsed <= NETWORK_READY_TIMEOUT_SECONDS )); do
        missing=$(network_state_missing)
        if [[ -z "$missing" ]] && verify_network_state; then
            return 0
        fi
        report INFO network "post-apply validation pending (${elapsed}s/${NETWORK_READY_TIMEOUT_SECONDS}s): $missing"
        (( elapsed >= NETWORK_READY_TIMEOUT_SECONDS )) && break
        sleep "$NETWORK_READY_INTERVAL_SECONDS"
        elapsed=$((elapsed + NETWORK_READY_INTERVAL_SECONDS))
    done
    missing=$(network_state_missing)
    report WARN network "post-apply validation timed out after ${NETWORK_READY_TIMEOUT_SECONDS}s: ${missing:-unknown state}"
    return 1
}

write_netplan_config() {
    local file='/etc/netplan/99-powerseven.yaml' temporary
    local vmnet_mac bridged_mac
    vmnet_mac=$(get_interface_mac "$VMNET8_IF")
    bridged_mac=$(get_interface_mac "$BRIDGED_IF")
    [[ "$vmnet_mac" =~ ^[0-9a-fA-F:]{17}$ && "$bridged_mac" =~ ^[0-9a-fA-F:]{17}$ ]] || return 1
    install -d -m 0750 "$NETWORK_STATE_DIR/backups"
    printf '%s\n' "$NETWORK_TRANSACTION_ID" > "$NETWORK_STATE_DIR/pending-token"
    printf '%s\n' "$VMNET8_IF" > "$NETWORK_STATE_DIR/underlay-interface"
    printf '%s\n' "$BRIDGED_IF" > "$NETWORK_STATE_DIR/bridged-interface"
    temporary=$(mktemp /etc/netplan/.powerseven-netplan.XXXXXX)
    printf '%s\n' "network:" \
        '  version: 2' \
        '  renderer: networkd' \
        '  ethernets:' \
        '    powerseven-underlay:' \
        "      match: {macaddress: $vmnet_mac}" \
        '      addresses: [192.168.214.14/24]' \
        '      routes:' \
        '        - to: default' \
        '          via: 192.168.214.2' \
        '      nameservers:' \
        '        addresses: [192.168.214.13]' \
        '    powerseven-bridged:' \
        "      match: {macaddress: $bridged_mac}" \
        '      dhcp4: true' \
        '      dhcp4-overrides:' \
        '        use-routes: false' \
        '        use-dns: false' > "$temporary"
    chown root:root "$temporary"
    chmod 600 "$temporary"
    mv -f "$temporary" "$file"
}

backup_netplan() {
    local backup="$NETWORK_STATE_DIR/backups/$NETWORK_TRANSACTION_ID"
    local file
    local -a files=()
    cancel_pending_network_transactions
    mkdir -p "$backup"
    rm -f "$backup"/*.yaml "$backup"/*.yml
    shopt -s nullglob
    files=(/etc/netplan/*.yaml /etc/netplan/*.yml)
    printf '%s\n' "$NETWORK_TRANSACTION_ID" > "$NETWORK_STATE_DIR/pending-token"
    printf '%s\n' "$backup" > "$NETWORK_STATE_DIR/pending-backup"
    for file in "${files[@]}"; do
        cp -a "$file" "$backup/"
    done
    for file in "${files[@]}"; do rm -f "$file"; done
    shopt -u nullglob
}

schedule_network_rollback() {
    local unit="powerseven-netplan-rollback-$NETWORK_TRANSACTION_ID"
    local script="$NETWORK_PENDING_DIR/netplan-rollback-$NETWORK_TRANSACTION_ID.sh"
    local marker="$NETWORK_PENDING_DIR/netplan-pending-$NETWORK_TRANSACTION_ID"
    local running_marker="$NETWORK_PENDING_DIR/netplan-running-$NETWORK_TRANSACTION_ID"
    local backup
    backup=$(cat "$NETWORK_STATE_DIR/pending-backup")
    install -d -m 0750 "$NETWORK_PENDING_DIR"
    : > "$marker"
    cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
lock='$NETWORK_LOCK_FILE'
exec 9>"\$lock"
flock -x 9
pending=\$(cat '$NETWORK_STATE_DIR/pending-token' 2>/dev/null || true)
if [[ "\$pending" != '$NETWORK_TRANSACTION_ID' || ! -e '$marker' ]]; then exit 0; fi
mv '$marker' '$running_marker'
shopt -s nullglob
for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do rm -f "\$file"; done
shopt -u nullglob
[[ -d '$backup' ]] || exit 1
cp -a '$backup'/. /etc/netplan/
netplan generate
netplan apply
rm -f '$running_marker' '$script' '$NETWORK_STATE_DIR/pending-token' '$NETWORK_STATE_DIR/pending-backup'
rm -rf '$backup'
EOF
    chmod 700 "$script"
    systemd-run --quiet --unit="$unit" --on-active=90s --collect /usr/bin/bash "$script"
}

rollback_network_now() {
    local transaction_id="$1" backup marker running_marker script pending
    backup=$(cat "$NETWORK_STATE_DIR/pending-backup" 2>/dev/null || true)
    marker="$NETWORK_PENDING_DIR/netplan-pending-$transaction_id"
    running_marker="$NETWORK_PENDING_DIR/netplan-running-$transaction_id"
    script="$NETWORK_PENDING_DIR/netplan-rollback-$transaction_id.sh"
    stop_network_rollback_unit "$transaction_id"
    acquire_network_lock
    pending=$(cat "$NETWORK_STATE_DIR/pending-token" 2>/dev/null || true)
    if [[ "$pending" != "$transaction_id" || -e "$running_marker" ]]; then
        release_network_lock
        report WARN network 'rollback state belongs to another transaction or is already running; leaving it untouched'
        return 1
    fi
    if [[ "$backup" != "$NETWORK_STATE_DIR/backups/"* || ! -d "$backup" ]]; then
        release_network_lock
        report FAIL network 'rollback backup is missing; refusing to delete the active Netplan configuration'
        return 1
    fi
    rm -f "$marker"
    shopt -s nullglob
    local file
    for file in /etc/netplan/*.yaml /etc/netplan/*.yml; do rm -f "$file"; done
    shopt -u nullglob
    cp -a "$backup"/. /etc/netplan/
    if ! netplan generate || ! netplan apply; then
        release_network_lock
        report FAIL network 'rollback could not restore and apply the previous Netplan configuration'
        return 1
    fi
    rm -f "$running_marker" "$script" "$NETWORK_STATE_DIR/pending-token" "$NETWORK_STATE_DIR/pending-backup"
    rm -rf "$backup"
    release_network_lock
}

commit_network_transaction() {
    local transaction_id="$1" backup marker running_marker script unit pending missing_state
    backup=$(cat "$NETWORK_STATE_DIR/pending-backup" 2>/dev/null || true)
    marker="$NETWORK_PENDING_DIR/netplan-pending-$transaction_id"
    running_marker="$NETWORK_PENDING_DIR/netplan-running-$transaction_id"
    script="$NETWORK_PENDING_DIR/netplan-rollback-$transaction_id.sh"
    unit="powerseven-netplan-rollback-$transaction_id"
    stop_network_rollback_unit "$transaction_id"
    if systemctl is-active --quiet "$unit.timer" 2>/dev/null || systemctl is-active --quiet "$unit.service" 2>/dev/null; then
        report FAIL network-confirm 'rollback timer/service is still active; preserving backup and pending state'
        return 1
    fi
    acquire_network_lock
    pending=$(cat "$NETWORK_STATE_DIR/pending-token" 2>/dev/null || true)
    if [[ "$pending" != "$transaction_id" || ! -e "$marker" || -e "$running_marker" ]]; then
        release_network_lock
        report FAIL network-confirm 'rollback state changed or is already running; preserving backup and pending state'
        return 1
    fi
    if [[ "$backup" != "$NETWORK_STATE_DIR/backups/"* || ! -d "$backup" ]]; then
        release_network_lock
        report FAIL network-confirm 'transaction backup is missing; refusing to commit the network change'
        return 1
    fi
    missing_state=$(network_state_missing)
    if [[ -n "$missing_state" ]] || ! netplan_persistence_is_valid; then
        release_network_lock
        report FAIL network-confirm 'runtime or persistent Netplan validation failed; preserving rollback state'
        return 1
    fi
    rm -f "$marker" "$script" "$NETWORK_STATE_DIR/pending-token" "$NETWORK_STATE_DIR/pending-backup"
    rm -rf "$backup"
    release_network_lock
}

confirm_network() {
    local pending
    pending=$(cat "$NETWORK_STATE_DIR/pending-token" 2>/dev/null || true)
    [[ -n "$pending" && "$pending" == "$CONFIRM_NETWORK_TRANSACTION_ID" ]] || {
        report FAIL network-confirm 'network transaction token is missing or does not match'; return 1;
    }
    detect_network_interfaces || {
        report FAIL network-confirm 'could not rediscover the VMnet8 and bridged interfaces'; return 1;
    }
    verify_network_state || {
        report FAIL network-confirm 'post-transition network validation failed'; return 1;
    }
    commit_network_transaction "$CONFIRM_NETWORK_TRANSACTION_ID"
    report PASS network-confirm 'DHCP-to-static network transition committed'
}

network_checkpoint() {
    if ! require_commands ip awk grep netplan readlink networkctl flock systemd-run systemctl; then
        return 1
    fi
    if [[ -n "$CONFIRM_NETWORK_TRANSACTION_ID" ]]; then
        confirm_network
        return $?
    fi
    if [[ "$MODE" == 'check' ]]; then
        if ! detect_network_interfaces; then
            if [[ ! -f '/etc/netplan/99-powerseven.yaml' ]]; then
                report MISSING network-persistence '99-powerseven.yaml is absent; runtime network cannot be considered boot-safe'
            else
                report MISSING network-persistence 'NIC discovery failed; persistent Netplan cannot be validated safely'
            fi
            report SKIP network 'expected exactly one VMnet8 Ethernet interface and one other Ethernet candidate; bridged IPv4 may be none before apply'
            return 0
        fi
        report_network_state || true
        if ! verify_network_state; then
            report MISSING network 'static 192.168.214.14, bridged DHCP/no-default-route, or DNS 192.168.214.13 is not ready'
        fi
        return 0
    fi
    [[ -n "$NETWORK_TRANSACTION_ID" ]] || NETWORK_TRANSACTION_ID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
    if detect_network_interfaces && verify_network_state; then
        report PASS network 'two-NIC configuration already matches the target'
        return 0
    fi
    if ! detect_network_interfaces; then
        report FAIL network 'could not identify exactly one VMnet8 Ethernet NIC and one unique bridged Ethernet NIC'
        return 1
    fi
    if ! backup_netplan; then
        report FAIL network 'could not create an isolated Netplan backup for the transaction'
        return 1
    fi
    write_netplan_config || { report FAIL network 'could not write the staged Netplan configuration'; rollback_network_now "$NETWORK_TRANSACTION_ID"; return 1; }
    schedule_network_rollback || { report FAIL network 'could not schedule automatic Netplan rollback'; rollback_network_now "$NETWORK_TRANSACTION_ID"; return 1; }
    if ! netplan generate || ! netplan apply; then
        report FAIL network 'Netplan apply failed; restoring the previous configuration'
        rollback_network_now "$NETWORK_TRANSACTION_ID"
        return 1
    fi
    if ! wait_for_network_state; then
        report FAIL network 'post-apply validation failed; restoring the previous configuration'
        rollback_network_now "$NETWORK_TRANSACTION_ID"
        return 1
    fi
    report PASS network 'configuration applied; awaiting runner confirmation before commit'
}

ensure_wireguard_server_keys() {
    local temporary_key temporary_pub expected_public
    install -d -m 0700 /etc/wireguard
    if [[ ! -s "$WG_SERVER_KEY" ]]; then
        temporary_key=$(mktemp /etc/wireguard/.powerseven-server-key.XXXXXX)
        umask 077
        wg genkey > "$temporary_key"
        chmod 600 "$temporary_key"
        mv -f "$temporary_key" "$WG_SERVER_KEY"
    fi
    expected_public=$(wg pubkey < "$WG_SERVER_KEY")
    if [[ ! -s "$WG_SERVER_PUB" ]] || [[ "$(tr -d '[:space:]' < "$WG_SERVER_PUB")" != "$expected_public" ]]; then
        temporary_pub=$(mktemp /etc/wireguard/.powerseven-server-pub.XXXXXX)
        printf '%s\n' "$expected_public" > "$temporary_pub"
        chmod 644 "$temporary_pub"
        mv -f "$temporary_pub" "$WG_SERVER_PUB"
    fi
    [[ -s "$WG_SERVER_KEY" && -s "$WG_SERVER_PUB" ]] || return 1
}

ensure_wireguard_config() {
    local server_private_key client_public_key
    server_private_key=$(cat "$WG_SERVER_KEY")
    install -d -m 0700 /etc/wireguard
    if [[ ! -f "$WG_CONFIG" ]]; then
        umask 077
        cat > "$WG_CONFIG" <<EOF
[Interface]
Address = $ADMIN_SERVER_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $server_private_key
EOF
    fi
    chmod 600 "$WG_CONFIG"
    if [[ -f "$WG_CLIENT_STATE" ]]; then
        client_public_key=$(tr -d '[:space:]' < "$WG_CLIENT_STATE")
        if [[ ! "$client_public_key" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ]]; then
            report FAIL admin-vpn-client 'stored client public key is invalid'
            return 1
        fi
        if ! grep -Fq "PublicKey = $client_public_key" "$WG_CONFIG"; then
            cat >> "$WG_CONFIG" <<EOF

[Peer]
PublicKey = $client_public_key
AllowedIPs = $ADMIN_CLIENT_ADDRESS
EOF
        fi
    fi
    chmod 600 "$WG_CONFIG"
}

ensure_admin_firewall() {
    local firewall_file='/etc/powerseven/admin-vpn.nft'
    local firewall_script='/usr/local/lib/powerseven/apply-admin-firewall.sh'
    local firewall_unit='/etc/systemd/system/powerseven-admin-firewall.service'
    install -d -m 0750 /etc/powerseven /usr/local/lib/powerseven
    cat > "$firewall_file" <<EOF
table inet powerseven_admin {
    chain input {
        type filter hook input priority -100; policy accept;
        iifname "$BRIDGED_IF" udp dport $WG_PORT accept
        iifname "$BRIDGED_IF" ct state established,related accept
        iifname "$BRIDGED_IF" udp sport 67 udp dport 68 accept
        iifname "$BRIDGED_IF" drop
    }
    chain forward {
        type filter hook forward priority -100; policy accept;
        ct state established,related accept
        iifname "$WG_INTERFACE" oifname "$VMNET8_IF" ip saddr $ADMIN_NETWORK ip daddr $UNDERLAY_NETWORK accept
        iifname "$BRIDGED_IF" oifname "$VMNET8_IF" drop
        iifname "$BRIDGED_IF" drop
    }
}
EOF
    chmod 600 "$firewall_file"
    nft -c -f "$firewall_file"
    cat > "$firewall_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
nft list table inet powerseven_admin >/dev/null 2>&1 && nft delete table inet powerseven_admin || true
nft -f /etc/powerseven/admin-vpn.nft
EOF
    chmod 755 "$firewall_script"
    cat > "$firewall_unit" <<EOF
[Unit]
Description=PowerSeven administrative VPN firewall
After=network-online.target wg-quick@$WG_INTERFACE.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$firewall_script
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$firewall_unit"
    systemctl daemon-reload
    systemctl enable --now powerseven-admin-firewall.service
}

ensure_admin_forwarding() {
    local sysctl_file='/etc/sysctl.d/99-powerseven-admin-vpn.conf'
    printf '%s\n' 'net.ipv4.ip_forward=1' > "$sysctl_file"
    chmod 644 "$sysctl_file"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == '1' ]]
}

ensure_admin_client_export() (
    local client_private client_public temporary_key temporary_config export_user export_uid export_gid
    trap 'rm -f "${temporary_key:-}" "${temporary_config:-}"' EXIT
    detect_network_interfaces || { report FAIL admin-vpn 'cannot determine bridged interface for client endpoint'; return 1; }
    if [[ -f "$WG_CLIENT_STATE" ]]; then
        if [[ ! -f "$WG_CLIENT_EXPORT" ]]; then
            report FAIL admin-vpn-client 'client identity already exists but its staged config is unavailable; explicit rotation is required'
            return 1
        fi
        report PASS admin-vpn-client 'existing client identity and staged config reused'
        return 0
    fi

    export_user=${SUDO_USER:-}
    [[ -n "$export_user" ]] || { report FAIL admin-vpn-client 'SUDO_USER is unavailable; refusing to create a user-owned client export'; return 1; }
    export_uid=$(id -u "$export_user")
    export_gid=$(id -g "$export_user")
    install -d -m 0700 -o root -g root "$WG_CLIENT_STATE_DIR"
    temporary_key=$(mktemp /tmp/.powerseven-client-key.XXXXXX)
    temporary_config=$(mktemp /tmp/.powerseven-client-config.XXXXXX)
    umask 077
    wg genkey > "$temporary_key"
    client_private=$(cat "$temporary_key")
    client_public=$(printf '%s\n' "$client_private" | wg pubkey)
    printf '%s\n' "$client_public" > "$WG_CLIENT_STATE"
    chmod 600 "$WG_CLIENT_STATE"
    ensure_wireguard_config
    printf '%s\n' \
        '[Interface]' \
        "Address = $ADMIN_CLIENT_ADDRESS" \
        "PrivateKey = $client_private" \
        "DNS = $UNDERLAY_DNS" \
        '' \
        '[Peer]' \
        "PublicKey = $(tr -d '[:space:]' < "$WG_SERVER_PUB")" \
        "Endpoint = ${BRIDGED_ADDRESS%/*}:$WG_PORT" \
        "AllowedIPs = $UNDERLAY_NETWORK,10.10.10.0/24" \
        'PersistentKeepalive = 25' > "$temporary_config"
    install -o "$export_uid" -g "$export_gid" -m 600 "$temporary_config" "$WG_CLIENT_EXPORT"
    rm -f "$temporary_key" "$temporary_config"
    systemctl enable --now "wg-quick@$WG_INTERFACE.service"
    wg set "$WG_INTERFACE" peer "$client_public" allowed-ips "$ADMIN_CLIENT_ADDRESS"
    report PASS admin-vpn-client 'client identity created and staged for key-only SCP export'
)

cleanup_admin_client_export() {
    [[ "$CLEANUP_CLIENT" -eq 1 ]] || return 0
    rm -f "$WG_CLIENT_EXPORT" /tmp/.powerseven-client-key.* /tmp/.powerseven-client-config.*
    [[ -f "$WG_CLIENT_STATE" ]] || { report FAIL admin-vpn-client 'cannot finalize client cleanup without persistent public key'; return 1; }
    report PASS admin-vpn-client 'client private key staging removed; public peer identity retained'
}

ensure_vpn_packages() {
    local package_needed=0
    if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
        package_needed=1
    fi
    if ! command -v nft >/dev/null 2>&1; then
        package_needed=1
    fi
    if (( package_needed )); then
        command -v apt-get >/dev/null 2>&1 || {
            report FAIL admin-vpn 'WireGuard/nftables are missing and apt-get is unavailable'; return 1;
        }
        apt-get install -y --no-install-recommends wireguard nftables
    fi
}

vpn_checkpoint() {
    if [[ "$MODE" == 'apply' ]]; then
        ensure_vpn_packages || return 1
    fi
    if ! require_commands ip wg wg-quick systemctl sysctl nft install mktemp awk grep; then
        return 1
    fi
    if ! detect_network_interfaces; then
        report FAIL admin-vpn 'requires one VMnet8 and one bridged interface with IPv4 addresses'
        return 1
    fi
    if ! verify_network_state; then
        report FAIL admin-vpn 'underlay/default-route/DNS state is not ready; refusing WireGuard changes'
        return 1
    fi
    if [[ "$MODE" == 'check' ]]; then
        if [[ -s "$WG_SERVER_KEY" && -s "$WG_SERVER_PUB" && -f "$WG_CONFIG" ]]; then
            report PASS admin-vpn-server 'persistent server key and configuration exist'
        else
            report MISSING admin-vpn-server 'WireGuard server key/configuration is not installed'
        fi
        if systemctl is-active --quiet "wg-quick@$WG_INTERFACE.service" && wg show "$WG_INTERFACE" >/dev/null 2>&1; then
            report PASS admin-vpn-interface "$WG_INTERFACE is active"
        else
            report MISSING admin-vpn-interface "$WG_INTERFACE is not active"
        fi
        if systemctl is-active --quiet powerseven-admin-firewall.service; then
            report PASS admin-vpn-firewall 'dedicated bridged ingress firewall is active'
        else
            report MISSING admin-vpn-firewall 'dedicated bridged ingress firewall is not active'
        fi
        if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)" == '1' ]]; then
            report PASS admin-vpn-forwarding 'IPv4 forwarding enabled'
        else
            report MISSING admin-vpn-forwarding 'IPv4 forwarding is disabled'
        fi
        if [[ -f "$WG_CLIENT_STATE" ]]; then
            report PASS admin-vpn-client 'persistent client public key exists'
        else
            report MISSING admin-vpn-client 'first client has not been staged'
        fi
        return 0
    fi
    ensure_wireguard_server_keys
    ensure_wireguard_config
    ensure_admin_forwarding
    systemctl enable --now "wg-quick@$WG_INTERFACE.service"
    if [[ "$CLEANUP_CLIENT" -eq 0 ]]; then
        ensure_admin_client_export
    else
        cleanup_admin_client_export
    fi
    ensure_admin_firewall
    report PASS admin-vpn "WireGuard $WG_INTERFACE configured at $ADMIN_SERVER_ADDRESS; bridged ingress is UDP/$WG_PORT only"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE='check'; shift ;;
        --apply) MODE='apply'; shift ;;
        --checkpoint)
            [[ $# -ge 2 ]] || { report FAIL arguments '--checkpoint requires a value'; exit 2; }
            CHECKPOINT="$2"
            shift 2
            ;;
        --network-token)
            [[ $# -ge 2 ]] || { report FAIL arguments '--network-token requires a value'; exit 2; }
            NETWORK_TRANSACTION_ID="$2"
            shift 2
            ;;
        --confirm-network)
            [[ $# -ge 2 ]] || { report FAIL arguments '--confirm-network requires a value'; exit 2; }
            CONFIRM_NETWORK_TRANSACTION_ID="$2"
            shift 2
            ;;
        --cleanup-client)
            CLEANUP_CLIENT=1
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) report FAIL arguments "unknown argument: $1"; usage; exit 2 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    report FAIL arguments 'choose exactly one mode: --check or --apply'
    usage
    exit 2
fi
if [[ "$MODE" == 'apply' && "$EUID" -ne 0 ]]; then
    report FAIL privileges 'apply requires root; use sudo'
    exit 2
fi
if [[ "$CHECKPOINT" != '1' && "$CHECKPOINT" != '2' && "$CHECKPOINT" != '3' ]]; then
    report FAIL "checkpoint$CHECKPOINT" 'only checkpoints 1, 2 and 3 are implemented'
    exit 2
fi
if [[ "$CHECKPOINT" == '1' && ( -n "$NETWORK_TRANSACTION_ID" || -n "$CONFIRM_NETWORK_TRANSACTION_ID" || "$CLEANUP_CLIENT" -eq 1 ) ]]; then
    report FAIL arguments 'network/client options are valid only for checkpoints 2 or 3'
    exit 2
fi
if [[ "$CHECKPOINT" == '2' && "$CLEANUP_CLIENT" -eq 1 ]]; then
    report FAIL arguments '--cleanup-client is valid only for checkpoint 3'
    exit 2
fi
if [[ "$CHECKPOINT" == '3' && ( -n "$NETWORK_TRANSACTION_ID" || -n "$CONFIRM_NETWORK_TRANSACTION_ID" ) ]]; then
    report FAIL arguments 'network transaction options are valid only for checkpoint 2'
    exit 2
fi
if [[ -n "$NETWORK_TRANSACTION_ID" && ! "$NETWORK_TRANSACTION_ID" =~ ^[a-f0-9]{32}$ ]] ||
   [[ -n "$CONFIRM_NETWORK_TRANSACTION_ID" && ! "$CONFIRM_NETWORK_TRANSACTION_ID" =~ ^[a-f0-9]{32}$ ]]; then
    report FAIL arguments 'network transaction id must be 32 lowercase hexadecimal characters'
    exit 2
fi

report PASS hostname "$(hostname)"
case "$CHECKPOINT" in
    1)
        if [[ "$MODE" == 'check' ]]; then
            storage_checkpoint
            if (( CHECK_NEEDS_APPLY )); then exit 1; fi
        else
            storage_checkpoint
        fi
        ;;
    2)
        network_checkpoint
        ;;
    3)
        vpn_checkpoint
        ;;
esac
