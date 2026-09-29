#!/usr/bin/env bash
set -euo pipefail

MODE=''
CHECKPOINT='1'
CHECK_NEEDS_APPLY=0
NETWORK_TRANSACTION_ID=''
CONFIRM_NETWORK_TRANSACTION_ID=''
CLEANUP_CLIENT=''
PEER_NAMES_CSV=''
declare -a ADMIN_PEERS=()
readonly POWERSEVEN_BOOTSTRAP_VERSION='15'
readonly POWERSEVEN_BOOTSTRAP_CAPABILITIES='1,2,3,4'
readonly MIN_FREE_BYTES=$((1024 * 1024))
readonly FS_MARGIN_BYTES=$((1024 * 1024 * 1024))
readonly UNDERLAY_NETWORK='192.168.214.0/24'
readonly ADMIN_CLIENT_ROUTES='192.168.214.0/25, 192.168.214.128/25'
readonly UNDERLAY_ADDRESS='192.168.214.14/24'
readonly UNDERLAY_GATEWAY='192.168.214.2'
readonly UNDERLAY_DNS='192.168.214.13'
readonly ADMIN_NETWORK='10.99.0.0/24'
readonly ADMIN_SERVER_ADDRESS='10.99.0.1/24'
readonly WG_INTERFACE='wg-admin'
readonly WG_PORT='51820'
readonly WG_CONFIG='/etc/wireguard/wg-admin.conf'
readonly WG_SERVER_KEY='/etc/wireguard/powerseven-wg-admin-server.key'
readonly WG_SERVER_PUB='/etc/wireguard/powerseven-wg-admin-server.pub'
readonly WG_CLIENT_STATE_DIR='/var/lib/powerseven/admin-vpn/clients'
readonly WG_PEER_INVENTORY='/var/lib/powerseven/admin-vpn/peers'
readonly NETWORK_STATE_DIR='/var/lib/powerseven/network'
readonly NETWORK_PENDING_DIR='/run/powerseven'
readonly NETWORK_LOCK_FILE='/run/powerseven/network.lock'
readonly NETWORK_READY_TIMEOUT_SECONDS=45
readonly NETWORK_READY_INTERVAL_SECONDS=2
readonly NETWORK_ROLLBACK_TIMEOUT_SECONDS=180
readonly NETWORKD_TAKEOVER_TIMEOUT_SECONDS=6
readonly DOCKER_CE_VERSION='5:29.8.1-1~ubuntu.24.04~noble'
readonly DOCKER_COMPOSE_VERSION='5.5.1-1~ubuntu.24.04~noble'
readonly CONTAINERD_IO_VERSION='2.3.6-1~ubuntu.24.04~noble'
readonly DOCKER_RUNTIME_DIR='/opt/powerseven/docker'
readonly DOCKER_FIREWALL_SCRIPT='/usr/local/lib/powerseven/apply-docker-user-firewall.sh'
readonly DOCKER_FIREWALL_UNIT='powerseven-docker-firewall.service'
readonly DOCKER_FIREWALL_DROPIN='/etc/systemd/system/docker.service.d/powerseven-firewall.conf'
RUNTIME_STAGE_ID=''

usage() {
    cat <<'EOF'
Usage: bootstrap.sh --check|--apply [--checkpoint N] [--peer-list name1,name2]
       bootstrap.sh --apply --checkpoint 4 --runtime-token TOKEN

Metadata:
  --version       print the bootstrap contract version
  --capabilities  print supported checkpoints
  --protocol      print version and capabilities for the runner

Implemented checkpoints:
  1  detect and expand the mounted root LVM using VG space already available
  2  configure the two-NIC local network with a rollback guard
  3  configure the WireGuard administrative VPN and chosen client peers
  4  install pinned Docker/Compose runtime and stage the service catalog

Checkpoint 4 does not start applications: image pins, application secrets,
host databases and service lifecycle configuration remain separate inputs.
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
    if [[ "$1" == 'MISSING' && "$MODE" == 'check' && "$CHECKPOINT" == '4' ]]; then
        CHECK_NEEDS_APPLY=1
    fi
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

networkd_read_link_state() {
    local interface="$1" mac status state_line
    NETWORKD_SETUP='unknown'
    NETWORKD_FILE='none'
    NETWORKD_EXPECTED='none'
    mac=$(get_interface_mac "$interface" 2>/dev/null || true)
    if [[ -n "$mac" ]]; then
        NETWORKD_EXPECTED=$(networkd_file_for_mac "$mac" 2>/dev/null || true)
        NETWORKD_EXPECTED=${NETWORKD_EXPECTED:-none}
    fi
    status=$(LC_ALL=C SYSTEMD_COLORS=0 SYSTEMD_URLIFY=0 networkctl --no-pager --no-legend status "$interface" 2>/dev/null) || return 0
    state_line=$(awk '/^[[:space:]]*State:/ { print; exit }' <<< "$status")
    if [[ "$state_line" =~ \((pending|initialized|configuring|configured|unmanaged|failed|linger)\)[[:space:]]*$ ]]; then
        NETWORKD_SETUP=${BASH_REMATCH[1]}
    fi
    NETWORKD_FILE=$(awk '/^[[:space:]]*Network File:/ {
        sub(/^[[:space:]]*Network File:[[:space:]]*/, ""); print; exit
    }' <<< "$status")
    NETWORKD_FILE=${NETWORKD_FILE:-none}
}

networkd_interface_is_configured() {
    networkd_read_link_state "$1"
    [[ "$NETWORKD_SETUP" == 'configured' && "$NETWORKD_EXPECTED" != 'none' && "$NETWORKD_FILE" == "$NETWORKD_EXPECTED" ]]
}

report_networkd_diagnostics() {
    local interface expected_mac actual_mac service_state
    service_state=$(systemctl is-active systemd-networkd.service 2>/dev/null || true)
    report WARN networkd-diagnostic "systemd-networkd=$service_state generated=/run/systemd/network"
    systemctl status --no-pager --full systemd-networkd.service 2>&1 | sed -n '1,12p' | while IFS= read -r line; do
        report INFO networkd-service-status "$line"
    done || true
    for interface in "$VMNET8_IF" "$BRIDGED_IF"; do
        [[ -n "$interface" ]] || continue
        expected_mac=$(get_interface_mac "$interface" 2>/dev/null || true)
        actual_mac=$(cat "/sys/class/net/$interface/address" 2>/dev/null || true)
        networkd_read_link_state "$interface"
        report WARN networkd-diagnostic "interface=$interface expected_mac=$expected_mac actual_mac=$actual_mac setup=$NETWORKD_SETUP network_file=$NETWORKD_FILE expected_file=$NETWORKD_EXPECTED"
        networkctl status --no-pager "$interface" 2>&1 | sed -n '1,12p' | while IFS= read -r line; do
            report INFO networkd-status "$line"
        done || true
    done
    find /run/systemd/network -maxdepth 1 -type f -name '*.network' -printf '%f\n' 2>/dev/null |
        while IFS= read -r file; do report INFO networkd-generated-file "$file"; done || true
}

networkd_interfaces_are_configured() {
    networkd_interface_is_configured "$VMNET8_IF" &&
        networkd_interface_is_configured "$BRIDGED_IF"
}

wait_for_networkd_configured() {
    local timeout="$1" elapsed=0
    while (( elapsed < timeout )); do
        networkd_interfaces_are_configured && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    networkd_interfaces_are_configured
}

wait_for_interface_configured() {
    local interface="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        networkd_interface_is_configured "$interface" && return 0
        sleep 1
        elapsed=$((elapsed + 1))
    done
    networkd_interface_is_configured "$interface"
}

ensure_networkd_takeover() {
    local reload_failed=0 phase_timeout=$((NETWORKD_TAKEOVER_TIMEOUT_SECONDS / 2))
    (( phase_timeout > 0 )) || phase_timeout=1
    if ! netplan_generated_networkd_is_valid; then
        report WARN networkd-takeover 'Netplan did not generate one MAC-matched .network file per NIC'
        report_networkd_diagnostics
        return 1
    fi
    if ! systemctl enable systemd-networkd.service ||
       { ! systemctl is-active --quiet systemd-networkd.service && ! systemctl start systemd-networkd.service; }; then
        report WARN networkd-takeover 'systemd-networkd could not be enabled or started'
        report_networkd_diagnostics
        return 1
    fi
    networkctl reload || reload_failed=1
    networkctl reconfigure "$VMNET8_IF" "$BRIDGED_IF" || reload_failed=1
    if (( reload_failed == 0 )) && wait_for_networkd_configured "$phase_timeout"; then
        report PASS networkd-takeover "reload/reconfigure manages $VMNET8_IF and $BRIDGED_IF"
        return 0
    fi
    report WARN networkd-takeover 'reload/reconfigure did not take ownership; attempting one protected networkd restart'
    if systemctl restart systemd-networkd.service; then
        networkctl reload || true
        networkctl reconfigure "$VMNET8_IF" "$BRIDGED_IF" || true
        if wait_for_networkd_configured "$phase_timeout"; then
            report PASS networkd-takeover "restart/reconfigure manages $VMNET8_IF and $BRIDGED_IF"
            return 0
        fi
    fi
    report FAIL networkd-takeover 'systemd-networkd still does not manage both interfaces'
    report_networkd_diagnostics
    return 1
}

reload_networkd_after_netplan() {
    local underlay_mac networkd_expected=0 phase_timeout=$((NETWORKD_TAKEOVER_TIMEOUT_SECONDS / 2))
    (( phase_timeout > 0 )) || phase_timeout=1
    underlay_mac=$(get_interface_mac "$VMNET8_IF" 2>/dev/null || true)
    if [[ -n "$underlay_mac" ]] && networkd_file_for_mac "$underlay_mac" >/dev/null 2>&1; then
        networkd_expected=1
    fi
    if (( networkd_expected )); then
        systemctl enable systemd-networkd.service || return 1
        systemctl is-active --quiet systemd-networkd.service || systemctl start systemd-networkd.service || return 1
    elif ! systemctl is-active --quiet systemd-networkd.service; then
        return 0
    fi
    if networkctl reload && networkctl reconfigure "$VMNET8_IF" "$BRIDGED_IF" &&
       { (( networkd_expected == 0 )) || wait_for_interface_configured "$VMNET8_IF" "$phase_timeout"; }; then
        return 0
    fi
    systemctl restart systemd-networkd.service &&
        networkctl reload &&
        networkctl reconfigure "$VMNET8_IF" "$BRIDGED_IF" &&
        { (( networkd_expected == 0 )) || wait_for_interface_configured "$VMNET8_IF" "$phase_timeout"; }
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

networkd_file_for_mac() {
    local mac="$1" file
    local -a matches=()
    for file in /run/systemd/network/*.network; do
        [[ -f "$file" ]] || continue
        if awk -v wanted="$mac" '
            /^\[Match\]$/ { in_match=1; next }
            /^\[/ { in_match=0 }
            in_match && /^(MACAddress|PermanentMACAddress)=/ {
                value=$0; sub(/^[^=]*=/, "", value)
                count=split(value, addresses, /[,[:space:]]+/)
                for (i=1; i<=count; i++) if (tolower(addresses[i]) == tolower(wanted)) found=1
            }
            END { exit !found }
        ' "$file"; then
            matches+=("$file")
        fi
    done
    [[ "${#matches[@]}" -eq 1 ]] || return 1
    printf '%s\n' "${matches[0]}"
}

netplan_generated_networkd_is_valid() {
    local vmnet_mac bridged_mac
    vmnet_mac=$(get_interface_mac "$VMNET8_IF")
    bridged_mac=$(get_interface_mac "$BRIDGED_IF")
    [[ "$vmnet_mac" =~ ^[0-9a-fA-F:]{17}$ && "$bridged_mac" =~ ^[0-9a-fA-F:]{17}$ ]] || return 1
    VMNET8_NETWORKD_FILE=$(networkd_file_for_mac "$vmnet_mac") || return 1
    BRIDGED_NETWORKD_FILE=$(networkd_file_for_mac "$bridged_mac") || return 1
    [[ "$VMNET8_NETWORKD_FILE" != "$BRIDGED_NETWORKD_FILE" ]]
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
    netplan generate >/dev/null 2>&1 && netplan_generated_networkd_is_valid
}

validate_netplan_persistence() {
    if ! netplan_persistence_is_valid; then
        report FAIL network-persistence '99-powerseven.yaml or its generated MAC-matched networkd files are missing or invalid'
        return 1
    fi
    report PASS network-persistence "99-powerseven.yaml and generated networkd files are valid: $VMNET8_NETWORKD_FILE, $BRIDGED_NETWORKD_FILE"
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
    if ! networkd_interfaces_are_configured; then
        report FAIL networkd 'both NICs must be configured by their MAC-matched Netplan network files'
        report_networkd_diagnostics
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

    if ! networkd_interface_is_configured "$VMNET8_IF"; then
        missing+="underlay networkd $NETWORKD_SETUP (file=$NETWORKD_FILE expected=$NETWORKD_EXPECTED); "
    fi
    if ! networkd_interface_is_configured "$BRIDGED_IF"; then
        missing+="bridged networkd $NETWORKD_SETUP (file=$NETWORKD_FILE expected=$NETWORKD_EXPECTED); "
    fi
    systemctl is-active --quiet systemd-networkd.service || missing+='systemd-networkd inactive; '
    systemctl is-enabled --quiet systemd-networkd.service || missing+='systemd-networkd disabled; '

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
    local timeout="${1:-$NETWORK_READY_TIMEOUT_SECONDS}" deadline elapsed remaining missing last_missing='' sleep_for
    deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        elapsed=$((timeout - (deadline - SECONDS)))
        missing=$(network_state_missing)
        last_missing=$missing
        if [[ -z "$missing" ]] && verify_network_state; then
            return 0
        fi
        report INFO network "post-apply validation pending (${elapsed}s/${timeout}s): $missing"
        remaining=$((deadline - SECONDS))
        (( remaining > 0 )) || break
        sleep_for=$NETWORK_READY_INTERVAL_SECONDS
        (( sleep_for > remaining )) && sleep_for=$remaining
        (( sleep_for > 0 )) || break
        sleep "$sleep_for"
    done
    report WARN network "post-apply validation timed out after ${timeout}s: ${last_missing:-unknown state}"
    if [[ "$last_missing" == *'networkd'* ]]; then report_networkd_diagnostics; fi
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
underlay_iface='$VMNET8_IF'
bridged_iface='$BRIDGED_IF'
vmnet_mac=\$(cat "/sys/class/net/\$underlay_iface/address")
networkd_expected=0
expected_network_file=''
for netfile in /run/systemd/network/*.network; do
    [[ -f "\$netfile" ]] || continue
    if awk -v wanted="\$vmnet_mac" '
        /^\[Match\]$/ { in_match=1; next }
        /^\[/ { in_match=0 }
        in_match && /^(MACAddress|PermanentMACAddress)=/ {
            value=\$0; sub(/^[^=]*=/, "", value)
            count=split(value, addresses, /[,[:space:]]+/)
            for (i=1; i<=count; i++) if (tolower(addresses[i]) == tolower(wanted)) found=1
        }
        END { exit !found }
    ' "\$netfile"; then networkd_expected=1; expected_network_file=\$netfile; break; fi
done
rollback_underlay_configured() {
    local status
    status=\$(LC_ALL=C SYSTEMD_COLORS=0 SYSTEMD_URLIFY=0 networkctl --no-pager --no-legend status "\$underlay_iface" 2>/dev/null) || return 1
    awk -v expected="\$expected_network_file" '
        /^[[:space:]]*State:/ && /\(configured\)[[:space:]]*\$/ { configured=1 }
        /^[[:space:]]*Network File:/ {
            sub(/^[[:space:]]*Network File:[[:space:]]*/, "")
            if (\$0 == expected) file_matches=1
        }
        END { exit !(configured && file_matches) }
    ' <<< "\$status"
}
if (( networkd_expected )); then
    systemctl enable systemd-networkd.service
    systemctl is-active --quiet systemd-networkd.service || systemctl start systemd-networkd.service
fi
if systemctl is-active --quiet systemd-networkd.service; then
    if ! networkctl reload || ! networkctl reconfigure "\$underlay_iface" "\$bridged_iface"; then
        systemctl restart systemd-networkd.service
        networkctl reload
        networkctl reconfigure "\$underlay_iface" "\$bridged_iface"
    fi
    if (( networkd_expected )); then
        for attempt in 1 2 3 4 5; do
            rollback_underlay_configured && break
            sleep 1
        done
        if ! rollback_underlay_configured; then
            networkctl --no-pager status "\$underlay_iface" >&2 || true
            exit 1
        fi
    fi
fi
rm -f '$running_marker' '$script' '$NETWORK_STATE_DIR/pending-token' '$NETWORK_STATE_DIR/pending-backup'
rm -rf '$backup'
EOF
    chmod 700 "$script"
    systemd-run --quiet --unit="$unit" --on-active="${NETWORK_ROLLBACK_TIMEOUT_SECONDS}s" --collect /usr/bin/bash "$script"
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
    if ! netplan generate || ! netplan apply || ! reload_networkd_after_netplan; then
        release_network_lock
        report FAIL network 'rollback could not restore Netplan and reload/reconfigure systemd-networkd'
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
    stop_network_rollback_unit "$transaction_id"
    if systemctl is-active --quiet "$unit.timer" 2>/dev/null || systemctl is-active --quiet "$unit.service" 2>/dev/null; then
        release_network_lock
        report FAIL network-confirm 'rollback timer/service is still active; preserving backup and pending state'
        return 1
    fi
    rm -f "$marker" "$script" "$NETWORK_STATE_DIR/pending-token" "$NETWORK_STATE_DIR/pending-backup"
    rm -rf "$backup"
    release_network_lock
}

confirm_network() {
    local pending confirm_started=$SECONDS elapsed remaining
    pending=$(cat "$NETWORK_STATE_DIR/pending-token" 2>/dev/null || true)
    [[ -n "$pending" && "$pending" == "$CONFIRM_NETWORK_TRANSACTION_ID" ]] || {
        report FAIL network-confirm 'network transaction token is missing or does not match'; return 1;
    }
    VMNET8_IF=$(cat "$NETWORK_STATE_DIR/underlay-interface" 2>/dev/null || true)
    BRIDGED_IF=$(cat "$NETWORK_STATE_DIR/bridged-interface" 2>/dev/null || true)
    if [[ ! "$VMNET8_IF" =~ ^[a-zA-Z0-9_.:-]+$ || ! "$BRIDGED_IF" =~ ^[a-zA-Z0-9_.:-]+$ || "$VMNET8_IF" == "$BRIDGED_IF" ]] ||
       ! ip link show dev "$VMNET8_IF" >/dev/null 2>&1 ||
       ! ip link show dev "$BRIDGED_IF" >/dev/null 2>&1; then
        report FAIL network-confirm 'stored network interfaces are missing or invalid; rollback guard remains active'
        return 1
    fi
    if ! networkd_interfaces_are_configured ||
       ! systemctl is-active --quiet systemd-networkd.service ||
       ! systemctl is-enabled --quiet systemd-networkd.service; then
        if ! ensure_networkd_takeover; then
            report FAIL network-confirm 'networkd takeover failed; rollback guard remains active'
            return 1
        fi
    fi
    elapsed=$((SECONDS - confirm_started))
    remaining=$((NETWORK_READY_TIMEOUT_SECONDS - elapsed))
    if (( remaining <= 0 )) || ! wait_for_network_state "$remaining"; then
        report FAIL network-confirm 'network readiness timed out; rollback guard remains active'
        return 1
    fi
    if ! commit_network_transaction "$CONFIRM_NETWORK_TRANSACTION_ID"; then
        report FAIL network-confirm 'validated network could not be committed; rollback guard remains active'
        return 1
    fi
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
    if ! netplan generate || ! netplan_generated_networkd_is_valid; then
        report FAIL network 'Netplan did not generate valid MAC-matched networkd files; restoring the previous configuration'
        report_networkd_diagnostics
        rollback_network_now "$NETWORK_TRANSACTION_ID"
        return 1
    fi
    if ! netplan apply; then
        report FAIL network 'Netplan apply failed; restoring the previous configuration'
        rollback_network_now "$NETWORK_TRANSACTION_ID"
        return 1
    fi
    if ! ensure_networkd_takeover; then
        report FAIL network 'systemd-networkd takeover failed; restoring the previous configuration'
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

admin_peer_names_to_addresses() {
    local name index=2
    local -A seen=()
    ADMIN_PEERS=()
    (( $# >= 1 && $# <= 253 )) || { report FAIL admin-vpn-peers 'choose 1 to 253 peers'; return 1; }
    for name in "$@"; do
        [[ "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ && -z "${seen[$name]:-}" ]] || {
            report FAIL admin-vpn-peers "invalid or duplicate peer name: $name"; return 1;
        }
        seen[$name]=1
        ADMIN_PEERS+=("$name:10.99.0.$index/32")
        (( index++ ))
    done
}

load_admin_peers() {
    local mode="$1" name public address octet offset pair file temporary_inventory inventory_dir
    local -a names=() requested=() state_files=() config_pairs=() ordered_names=()
    local -A address_by_key=() used_keys=()
    if [[ -n "$PEER_NAMES_CSV" ]]; then
        [[ "$PEER_NAMES_CSV" =~ ^[a-z][a-z0-9_-]{0,31}(,[a-z][a-z0-9_-]{0,31})*$ ]] || {
            report FAIL admin-vpn-peers 'peer list must contain distinct lowercase names separated by commas'; return 1;
        }
        IFS=',' read -r -a requested <<< "$PEER_NAMES_CSV"
        admin_peer_names_to_addresses "${requested[@]}" || return 1
    fi
    if [[ -e "$WG_PEER_INVENTORY" ]]; then
        [[ -f "$WG_PEER_INVENTORY" ]] || { report FAIL admin-vpn-peers 'peer inventory is not a regular file'; return 1; }
        mapfile -t names < "$WG_PEER_INVENTORY"
    else
        if [[ -d "$WG_CLIENT_STATE_DIR" ]]; then
            while IFS= read -r -d '' file; do state_files+=("$file"); done < <(find "$WG_CLIENT_STATE_DIR" -maxdepth 1 -type f -name '*.pub' -print0)
        fi
        if (( ${#state_files[@]} > 0 )); then
            [[ -f "$WG_CONFIG" ]] || {
                report FAIL admin-vpn-peers 'legacy peer state has no WireGuard configuration'; return 1;
            }
            mapfile -t config_pairs < <(awk '
                /^\[Peer\]$/ { if (peer) print key "|" address; peer=1; key=""; address=""; next }
                peer && /^PublicKey = / { key=$3 }
                peer && /^AllowedIPs = / { address=$3 }
                END { if (peer) print key "|" address }
            ' "$WG_CONFIG")
            (( ${#config_pairs[@]} == ${#state_files[@]} )) || {
                report FAIL admin-vpn-peers 'legacy public keys and WireGuard peer entries differ'; return 1;
            }
            for pair in "${config_pairs[@]}"; do
                IFS='|' read -r public address <<< "$pair"
                [[ "$public" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ && "$address" =~ ^10\.99\.0\.([0-9]{1,3})/32$ && -z "${address_by_key[$public]:-}" ]] || {
                    report FAIL admin-vpn-peers 'legacy WireGuard peer entry is invalid or duplicated'; return 1;
                }
                address_by_key[$public]=$address
            done
            for file in "${state_files[@]}"; do
                name=${file##*/}; name=${name%.pub}
                public=$(tr -d '[:space:]' < "$file")
                address=${address_by_key[$public]:-}
                [[ -n "$address" && -z "${used_keys[$public]:-}" && "$address" =~ ^10\.99\.0\.([0-9]{1,3})/32$ ]] || {
                    report FAIL admin-vpn-peers "cannot match legacy identity for $name"; return 1;
                }
                used_keys[$public]=1
                octet=${BASH_REMATCH[1]}
                (( octet >= 2 && octet <= 254 )) || { report FAIL admin-vpn-peers 'legacy peer address is outside the admin pool'; return 1; }
                offset=$((octet - 2))
                [[ -z "${ordered_names[$offset]:-}" ]] || { report FAIL admin-vpn-peers 'legacy peer addresses are duplicated'; return 1; }
                ordered_names[$offset]=$name
            done
            for (( offset=0; offset<${#state_files[@]}; offset++ )); do
                [[ -n "${ordered_names[$offset]:-}" ]] || { report FAIL admin-vpn-peers 'legacy peer addresses are not contiguous from 10.99.0.2'; return 1; }
                names+=("${ordered_names[$offset]}")
            done
        elif [[ -f "$WG_CONFIG" ]] && grep -q '^\[Peer\]$' "$WG_CONFIG"; then
            report FAIL admin-vpn-peers 'WireGuard peers exist without public identity files'; return 1
        elif (( ${#requested[@]} > 0 )); then
            names=("${requested[@]}")
        fi
    fi
    if (( ${#names[@]} == 0 )); then ADMIN_PEERS=(); return 0; fi
    admin_peer_names_to_addresses "${names[@]}" || return 1
    if (( ${#requested[@]} > 0 )); then
        [[ "$(IFS=,; printf '%s' "${requested[*]}")" == "$(IFS=,; printf '%s' "${names[*]}")" ]] || {
            report FAIL admin-vpn-peers 'requested peers differ from the persistent inventory'; return 1;
        }
    fi
    if [[ "$mode" == 'write' && ! -e "$WG_PEER_INVENTORY" ]]; then
        inventory_dir=${WG_PEER_INVENTORY%/*}
        install -d -m 0700 "$inventory_dir"
        temporary_inventory=$(mktemp "$inventory_dir/.peers.XXXXXX")
        printf '%s\n' "${names[@]}" > "$temporary_inventory"
        chmod 600 "$temporary_inventory"
        mv -f "$temporary_inventory" "$WG_PEER_INVENTORY"
    fi
}

admin_peer_address() {
    local peer
    for peer in "${ADMIN_PEERS[@]}"; do
        if [[ "${peer%%:*}" == "$1" ]]; then printf '%s\n' "${peer#*:}"; return 0; fi
    done
    return 1
}

ensure_wireguard_config() (
    local server_private_key client_public_key peer peer_name peer_address peer_state temporary_config
    local -A seen_public=()
    trap 'rm -f "${temporary_config:-}"' EXIT
    server_private_key=$(cat "$WG_SERVER_KEY")
    install -d -m 0700 /etc/wireguard
    temporary_config=$(mktemp /etc/wireguard/.wg-admin.XXXXXX)
    chmod 600 "$temporary_config"
    cat > "$temporary_config" <<EOF
[Interface]
Address = $ADMIN_SERVER_ADDRESS
ListenPort = $WG_PORT
PrivateKey = $server_private_key
EOF
    for peer in "${ADMIN_PEERS[@]}"; do
        peer_name=${peer%%:*}; peer_address=${peer#*:}
        peer_state="$WG_CLIENT_STATE_DIR/$peer_name.pub"
        [[ -s "$peer_state" ]] || { report FAIL admin-vpn-client "$peer_name public identity is missing"; return 1; }
        client_public_key=$(tr -d '[:space:]' < "$peer_state")
        if [[ ! "$client_public_key" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ]]; then
            report FAIL admin-vpn-client 'stored client public key is invalid'
            return 1
        fi
        if [[ -n "${seen_public[$client_public_key]:-}" ]]; then
            report FAIL admin-vpn-client 'peer public keys are duplicated; explicit rotation is required'
            return 1
        fi
        seen_public[$client_public_key]=1
        cat >> "$temporary_config" <<EOF

[Peer]
PublicKey = $client_public_key
AllowedIPs = $peer_address
EOF
    done
    install -o root -g root -m 600 "$temporary_config" "$WG_CONFIG"
    rm -f "$temporary_config"
)

render_admin_firewall() {
    cat <<EOF
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
        iifname "$WG_INTERFACE" oifname "$VMNET8_IF" ip saddr $ADMIN_NETWORK ip daddr $UNDERLAY_NETWORK accept
        iifname "$WG_INTERFACE" drop
        ct state established,related accept
        iifname "$BRIDGED_IF" oifname "$VMNET8_IF" drop
        iifname "$BRIDGED_IF" drop
    }
}
EOF
}

admin_firewall_is_ready() {
    local firewall_file='/etc/powerseven/admin-vpn.nft'
    local firewall_script='/usr/local/lib/powerseven/apply-admin-firewall.sh'
    local firewall_unit='/etc/systemd/system/powerseven-admin-firewall.service'
    local wg_dropin='/etc/systemd/system/wg-quick@wg-admin.service.d/powerseven-firewall.conf'
    local expected installed active
    [[ -f "$firewall_file" && -x "$firewall_script" && -f "$firewall_unit" && -f "$wg_dropin" ]] || return 1
    grep -Fxq 'Before=network-pre.target wg-quick@wg-admin.service' "$firewall_unit" || return 1
    grep -Fxq "ExecStart=$firewall_script" "$firewall_unit" || return 1
    grep -Fxq 'Requires=powerseven-admin-firewall.service' "$wg_dropin" || return 1
    grep -Fxq 'After=powerseven-admin-firewall.service' "$wg_dropin" || return 1
    systemctl is-enabled --quiet powerseven-admin-firewall.service || return 1
    systemctl is-active --quiet powerseven-admin-firewall.service || return 1
    expected=$(render_admin_firewall)
    installed=$(cat "$firewall_file") || return 1
    [[ "$installed" == "$expected" ]] || return 1
    active=$(nft list table inet powerseven_admin 2>/dev/null) || return 1
    [[ "$(printf '%s' "$active" | tr -d '[:space:];"')" == "$(printf '%s' "$expected" | tr -d '[:space:];"')" ]]
}

ensure_admin_firewall() (
    local firewall_file='/etc/powerseven/admin-vpn.nft'
    local firewall_script='/usr/local/lib/powerseven/apply-admin-firewall.sh'
    local firewall_unit='/etc/systemd/system/powerseven-admin-firewall.service'
    local wg_dropin='/etc/systemd/system/wg-quick@wg-admin.service.d/powerseven-firewall.conf'
    local temp_config='' temp_script='' temp_unit='' temp_dropin=''
    if admin_firewall_is_ready; then return 0; fi
    trap 'rm -f "$temp_config" "$temp_script" "$temp_unit" "$temp_dropin"' EXIT
    install -d -m 0750 /etc/powerseven /usr/local/lib/powerseven
    install -d -m 0755 /etc/systemd/system/wg-quick@wg-admin.service.d
    temp_config=$(mktemp /etc/powerseven/.admin-vpn.nft.XXXXXX)
    render_admin_firewall > "$temp_config"
    if nft list table inet powerseven_admin >/dev/null 2>&1; then
        { printf 'delete table inet powerseven_admin\n'; cat "$temp_config"; } | nft -c -f -
    else
        nft -c -f "$temp_config"
    fi
    temp_script=$(mktemp /usr/local/lib/powerseven/.apply-admin-firewall.XXXXXX)
    cat > "$temp_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if nft list table inet powerseven_admin >/dev/null 2>&1; then
    { printf 'delete table inet powerseven_admin\n'; cat /etc/powerseven/admin-vpn.nft; } | nft -f -
else
    nft -f /etc/powerseven/admin-vpn.nft
fi
EOF
    chmod 755 "$temp_script"
    temp_unit=$(mktemp /etc/systemd/system/.powerseven-admin-firewall.XXXXXX)
    cat > "$temp_unit" <<EOF
[Unit]
Description=PowerSeven administrative VPN firewall
DefaultDependencies=no
After=local-fs.target
Wants=network-pre.target
Before=network-pre.target wg-quick@$WG_INTERFACE.service

[Service]
Type=oneshot
ExecStart=$firewall_script
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$temp_unit"
    temp_dropin=$(mktemp /etc/systemd/system/wg-quick@wg-admin.service.d/.powerseven-firewall.XXXXXX)
    cat > "$temp_dropin" <<'EOF'
[Unit]
Requires=powerseven-admin-firewall.service
After=powerseven-admin-firewall.service
EOF
    chmod 644 "$temp_dropin"
    mv -f "$temp_config" "$firewall_file"
    mv -f "$temp_script" "$firewall_script"
    mv -f "$temp_unit" "$firewall_unit"
    mv -f "$temp_dropin" "$wg_dropin"
    systemctl daemon-reload
    systemctl enable powerseven-admin-firewall.service
    systemctl restart powerseven-admin-firewall.service
    admin_firewall_is_ready || { report FAIL admin-vpn-firewall 'nftables rules did not match the CP3 policy'; return 1; }
)

ensure_admin_forwarding() {
    local sysctl_file='/etc/sysctl.d/99-powerseven-admin-vpn.conf'
    printf '%s\n' 'net.ipv4.ip_forward=1' > "$sysctl_file"
    chmod 644 "$sysctl_file"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == '1' ]]
}

ensure_admin_client_export() (
    local peer_name="$1" peer_address peer_state peer_export client_private client_public temporary_key temporary_config export_user export_uid export_gid
    peer_address=$(admin_peer_address "$peer_name") || { report FAIL admin-vpn-client 'unknown peer'; return 1; }
    peer_state="$WG_CLIENT_STATE_DIR/$peer_name.pub"
    peer_export="/tmp/powerseven-admin-$peer_name.conf"
    trap 'rm -f "${temporary_key:-}" "${temporary_config:-}"' EXIT
    if [[ -f "$peer_state" ]]; then
        if [[ -f "$peer_export" ]]; then
            client_private=$(sed -n 's/^PrivateKey = //p' "$peer_export")
            [[ -n "$client_private" ]] &&
                [[ "$(printf '%s\n' "$client_private" | wg pubkey)" == "$(tr -d '[:space:]' < "$peer_state")" ]] || {
                report FAIL admin-vpn-client "$peer_name staged config does not match its public identity"; return 1;
            }
        fi
        report PASS admin-vpn-client "$peer_name identity preserved; staged export=$([[ -f "$peer_export" ]] && printf yes || printf no)"
        return 0
    fi
    if [[ -f "$WG_CONFIG" ]] && grep -Fq "AllowedIPs = $peer_address" "$WG_CONFIG"; then
        report FAIL admin-vpn-client "$peer_name public identity is lost; explicit rotation is required"
        return 1
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
    printf '%s\n' \
        '[Interface]' \
        "Address = $peer_address" \
        "PrivateKey = $client_private" \
        '' \
        '[Peer]' \
        "PublicKey = $(tr -d '[:space:]' < "$WG_SERVER_PUB")" \
        "Endpoint = ${BRIDGED_ADDRESS%/*}:$WG_PORT" \
        "AllowedIPs = $ADMIN_CLIENT_ROUTES" \
        'PersistentKeepalive = 25' > "$temporary_config"
    install -o "$export_uid" -g "$export_gid" -m 600 "$temporary_config" "$peer_export"
    printf '%s\n' "$client_public" > "$peer_state"
    chmod 600 "$peer_state"
    rm -f "$temporary_key" "$temporary_config"
    report PASS admin-vpn-client "$peer_name identity created and staged for key-only SCP export"
)

cleanup_admin_client_export() {
    [[ -n "$CLEANUP_CLIENT" ]] || return 0
    admin_peer_address "$CLEANUP_CLIENT" >/dev/null || { report FAIL admin-vpn-client 'unknown peer'; return 1; }
    [[ -f "$WG_CLIENT_STATE_DIR/$CLEANUP_CLIENT.pub" ]] || { report FAIL admin-vpn-client 'cannot finalize client cleanup without persistent public key'; return 1; }
    rm -f "/tmp/powerseven-admin-$CLEANUP_CLIENT.conf"
    report PASS admin-vpn-client "$CLEANUP_CLIENT private key staging removed; public peer identity retained"
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

if [[ "$#" -eq 1 && "$1" == '--admin-endpoint' ]]; then
    [[ "$EUID" -eq 0 ]] || { printf '%s\n' 'admin endpoint requires root' >&2; exit 2; }
    detect_network_interfaces && [[ "$BRIDGED_ADDRESS" != 'none' ]] || exit 1
    printf '%s:%s\n' "${BRIDGED_ADDRESS%/*}" "$WG_PORT"
    exit 0
fi
if [[ "$#" -eq 1 && "$1" == '--peer-status' ]]; then
    [[ "$EUID" -eq 0 ]] || { printf '%s\n' 'peer status requires root' >&2; exit 2; }
    load_admin_peers read || exit 1
    for peer in "${ADMIN_PEERS[@]}"; do
        peer_name=${peer%%:*}; peer_address=${peer#*:}
        peer_state="$WG_CLIENT_STATE_DIR/$peer_name.pub"
        peer_export="/tmp/powerseven-admin-$peer_name.conf"
        if [[ -s "$peer_state" && -s "$peer_export" ]]; then status=staged
        elif [[ -s "$peer_state" ]]; then status=exported
        elif [[ -e "$peer_export" ]]; then status=invalid
        else status=absent
        fi
        printf '%s|%s|%s\n' "$peer_name" "$peer_address" "$status"
    done
    exit 0
fi

vpn_checkpoint() {
    local peer peer_name peer_address peer_public
    if [[ -n "$CLEANUP_CLIENT" ]]; then
        load_admin_peers read || return 1
        cleanup_admin_client_export
        return
    fi
    if [[ "$MODE" == 'apply' ]]; then
        ensure_vpn_packages || return 1
    fi
    if ! require_commands ip wg wg-quick systemctl sysctl nft install mktemp awk grep cat tr find; then
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
        load_admin_peers read || return 1
        if (( ${#ADMIN_PEERS[@]} == 0 )) || [[ ! -f "$WG_PEER_INVENTORY" ]]; then
            report MISSING admin-vpn-peers 'persistent peer inventory is not installed'
        fi
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
        if admin_firewall_is_ready; then
            report PASS admin-vpn-firewall 'persistent unit and loaded nftables rules match the CP3 policy'
        else
            report MISSING admin-vpn-firewall 'persistent unit or loaded nftables rules do not match the CP3 policy'
        fi
        if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)" == '1' ]]; then
            report PASS admin-vpn-forwarding 'IPv4 forwarding enabled'
        else
            report MISSING admin-vpn-forwarding 'IPv4 forwarding is disabled'
        fi
        for peer in "${ADMIN_PEERS[@]}"; do
            peer_name=${peer%%:*}; peer_address=${peer#*:}
            if [[ -f "$WG_CLIENT_STATE_DIR/$peer_name.pub" ]]; then
                peer_public=$(tr -d '[:space:]' < "$WG_CLIENT_STATE_DIR/$peer_name.pub")
                if [[ "$peer_public" =~ ^[A-Za-z0-9+/]{40,}={0,2}$ ]] &&
                   grep -Fq "PublicKey = $peer_public" "$WG_CONFIG" 2>/dev/null &&
                   grep -Fq "AllowedIPs = $peer_address" "$WG_CONFIG" 2>/dev/null &&
                   wg show "$WG_INTERFACE" allowed-ips 2>/dev/null | awk -v key="$peer_public" -v address="$peer_address" '$1 == key && $2 == address { found=1 } END { exit !found }'; then
                    report PASS admin-vpn-client "$peer_name public identity/config/runtime valid; staged export=$([[ -f "/tmp/powerseven-admin-$peer_name.conf" ]] && printf yes || printf no)"
                else
                    report MISSING admin-vpn-client "$peer_name identity exists but peer config/runtime is incomplete"
                fi
            else
                report MISSING admin-vpn-client "$peer_name public key missing"
            fi
        done
        return 0
    fi
    ensure_admin_firewall
    load_admin_peers write
    (( ${#ADMIN_PEERS[@]} > 0 )) || { report FAIL admin-vpn-peers 'first CP3 apply requires a peer list'; return 1; }
    ensure_wireguard_server_keys
    for peer in "${ADMIN_PEERS[@]}"; do
        ensure_admin_client_export "${peer%%:*}"
    done
    ensure_wireguard_config
    ensure_admin_forwarding
    systemctl enable --now "wg-quick@$WG_INTERFACE.service"
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_CONFIG")
    admin_firewall_is_ready || { report FAIL admin-vpn-firewall 'nftables policy disappeared during CP3 apply'; return 1; }
    report PASS admin-vpn "WireGuard $WG_INTERFACE configured at $ADMIN_SERVER_ADDRESS; bridged ingress is UDP/$WG_PORT only"
}

docker_package_version() {
    local version
    version=$(dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$1" 2>/dev/null || true)
    awk '$1 == "ii" { print $2; exit }' <<< "$version"
}

docker_firewall_rules_are_first() {
    iptables -w -L FORWARD -v -n --line-numbers 2>/dev/null |
        awk '$1 == "1" { found=($4 == "DOCKER-USER") } END { exit !found }' || return 1
    iptables -w -L DOCKER-USER -v -n --line-numbers 2>/dev/null |
        awk '
            $1 == "1" { first=($4 == "ACCEPT" && $7 == "*" && $8 == "wg-admin" && $9 == "192.168.214.0/24" && $10 == "10.99.0.0/24" && $0 ~ /ctstate/) }
            $1 == "2" { second=($4 == "ACCEPT" && $7 == "wg-admin" && $8 == "*" && $9 == "10.99.0.0/24" && $10 == "192.168.214.0/24" && $0 ~ /ctstate/) }
            END { exit !(first && second) }
        '
}

docker_firewall_is_ready() {
    local systemd_requirements
    [[ -f "$DOCKER_FIREWALL_SCRIPT" && -f "/etc/systemd/system/$DOCKER_FIREWALL_UNIT" && -f "$DOCKER_FIREWALL_DROPIN" ]] || return 1
    grep -Fxq 'Before=docker.service' "/etc/systemd/system/$DOCKER_FIREWALL_UNIT" || return 1
    grep -Fxq 'Requires=powerseven-admin-firewall.service powerseven-docker-firewall.service' "$DOCKER_FIREWALL_DROPIN" || return 1
    grep -Fxq 'After=powerseven-admin-firewall.service powerseven-docker-firewall.service' "$DOCKER_FIREWALL_DROPIN" || return 1
    systemd_requirements=$(systemctl show docker.service -p Requires --value 2>/dev/null || true)
    grep -Fq 'powerseven-docker-firewall.service' <<< "$systemd_requirements" || return 1
    systemctl is-enabled --quiet "$DOCKER_FIREWALL_UNIT" || return 1
    systemctl is-active --quiet "$DOCKER_FIREWALL_UNIT" || return 1
    systemctl is-enabled --quiet docker.service || return 1
    systemctl is-active --quiet docker.service || return 1
    docker_firewall_rules_are_first || return 1
    iptables -w -C FORWARD -j DOCKER-USER >/dev/null 2>&1 || return 1
    iptables -w -C DOCKER-USER -i "$WG_INTERFACE" -s "$ADMIN_NETWORK" -d "$UNDERLAY_NETWORK" \
        -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1 || return 1
    iptables -w -C DOCKER-USER -o "$WG_INTERFACE" -s "$UNDERLAY_NETWORK" -d "$ADMIN_NETWORK" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT >/dev/null 2>&1
}

docker_runtime_files_are_ready() {
    local manifest="$DOCKER_RUNTIME_DIR/.powerseven-managed-sha256" expected_compose expected_env actual
    [[ -d "$DOCKER_RUNTIME_DIR" && -f "$DOCKER_RUNTIME_DIR/compose.yml" && -f "$DOCKER_RUNTIME_DIR/.env.example" && -f "$manifest" ]] || return 1
    [[ "$(stat -c '%U:%G:%a' "$DOCKER_RUNTIME_DIR")" == 'root:root:755' ]] || return 1
    [[ "$(stat -c '%U:%G:%a' "$DOCKER_RUNTIME_DIR/compose.yml")" == 'root:root:644' ]] || return 1
    [[ "$(stat -c '%U:%G:%a' "$DOCKER_RUNTIME_DIR/.env.example")" == 'root:root:644' ]] || return 1
    [[ "$(stat -c '%U:%G:%a' "$manifest")" == 'root:root:644' ]] || return 1
    expected_compose=$(awk '$1 == "compose.yml" { print $2; exit }' "$manifest")
    expected_env=$(awk '$1 == ".env.example" { print $2; exit }' "$manifest")
    actual=$(sha256sum "$DOCKER_RUNTIME_DIR/compose.yml" | awk '{ print $1 }')
    [[ "$actual" == "$expected_compose" ]] || return 1
    actual=$(sha256sum "$DOCKER_RUNTIME_DIR/.env.example" | awk '{ print $1 }')
    [[ "$actual" == "$expected_env" ]]
}

docker_storage_check() {
    local docker_root docker_fs containerd_fs free_kib
    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    if [[ "$docker_root" == '/var/lib/docker' && -d /var/lib/docker && -d /var/lib/containerd &&
          "$(stat -c '%U' /var/lib/docker 2>/dev/null || true)" == root &&
          "$(stat -c '%U' /var/lib/containerd 2>/dev/null || true)" == root ]]; then
        docker_fs=$(findmnt -no FSTYPE -T /var/lib/docker 2>/dev/null || printf unknown)
        containerd_fs=$(findmnt -no FSTYPE -T /var/lib/containerd 2>/dev/null || printf unknown)
        free_kib=$(df -Pk /var/lib/docker | awk 'NR == 2 { print $4 }')
        report PASS docker-storage "DockerRootDir=$docker_root containerd=/var/lib/containerd filesystem=$docker_fs/$containerd_fs free_kib=${free_kib:-unknown}; data is retained"
    else
        report MISSING docker-storage 'expected root-owned /var/lib/docker and /var/lib/containerd on persistent storage'
        [[ "$MODE" != 'apply' ]] || return 1
    fi
}

docker_group_check() {
    local group members
    group=$(getent group docker 2>/dev/null || true)
    if [[ -z "$group" ]]; then
        report MISSING docker-group 'Docker group is absent'
        [[ "$MODE" != 'apply' ]] || return 1
        return 0
    fi
    members=$(awk -F: '{ print $4 }' <<< "$group")
    if [[ -z "$members" ]]; then
        report PASS docker-group 'group exists with no members; Docker commands remain root-only'
    else
        report MISSING docker-group 'Docker group has members; membership grants root-equivalent control and CP4 will not alter it'
        [[ "$MODE" != 'apply' ]] || return 1
    fi
}

docker_app_diagnostics() {
    local name state health port output
    local -a networks=(soc-adguard_default soc-cloud_cloudnet soc-forgejo_forgejonet soc-stirling_default soc-scribble_default)
    local -a volumes=(powerseven_adguard_work powerseven_adguard_config powerseven_nextcloud_config powerseven_nextcloud_data powerseven_nextcloud_redis powerseven_forgejo_data powerseven_stirling_data)
    local -a containers=(powerseven-adguard powerseven-nextcloud powerseven-nextcloud-redis powerseven-forgejo powerseven-stirling powerseven-scribble-1 powerseven-scribble-2)
    for name in "${networks[@]}"; do
        if docker network inspect "$name" >/dev/null 2>&1; then
            report INFO "docker-network:$name" 'present'
        else
            report INFO "docker-network:$name" 'absent; application deployment remains pending'
        fi
    done
    for name in "${volumes[@]}"; do
        if docker volume inspect "$name" >/dev/null 2>&1; then
            report INFO "docker-volume:$name" 'present; contents are left untouched'
        else
            report INFO "docker-volume:$name" 'absent; application deployment remains pending'
        fi
    done
    for name in "${containers[@]}"; do
        if state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null); then
            health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "$name" 2>/dev/null || printf 'unknown')
            report INFO "docker-container:$name" "state=$state health=$health"
        else
            report INFO "docker-container:$name" 'absent; CP4 stages the catalog but does not start applications'
        fi
    done
    if output=$(ss -H -lntup 2>/dev/null); then
        if grep -Eq '[:.]2375([^0-9]|$)|[:.]2376([^0-9]|$)' <<< "$output"; then
            report MISSING docker-api 'Docker TCP API port 2375/2376 has a listener; remote API must remain disabled'
        else
            report PASS docker-api 'no TCP listener on Docker remote API ports 2375/2376'
        fi
        for port in 53 3001 3002 8081 8082 8083 8084; do
            if grep -Eq ":${port}([^0-9]|$)" <<< "$output"; then
                report INFO "docker-port:$port" 'local listener present'
            else
                report INFO "docker-port:$port" 'no local listener; application deployment remains pending'
            fi
        done
    else
        report MISSING docker-ports 'ss is unavailable; local listeners cannot be checked'
    fi
    if timeout 2 bash -c ':</dev/tcp/192.168.214.14/5432' >/dev/null 2>&1; then
        report INFO external-postgresql '192.168.214.14:5432 accepts TCP'
    else
        report INFO external-postgresql '192.168.214.14:5432 is not reachable; host PostgreSQL is a separate milestone'
    fi
    if timeout 2 bash -c ':</dev/tcp/192.168.214.14/3306' >/dev/null 2>&1; then
        report INFO external-mariadb '192.168.214.14:3306 accepts TCP'
    else
        report INFO external-mariadb '192.168.214.14:3306 is not reachable; host MariaDB is a separate milestone'
    fi
    report INFO application-secrets 'LDAP endpoint/bind identity and application secrets are not modeled; no secret was copied to VPS14'
    report INFO docker-healthchecks 'the current Compose catalog declares no service healthchecks'
}

docker_foundation_check() {
    local os_id os_version os_codename architecture expected actual package name
    os_id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    os_version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    os_codename=$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    architecture=$(dpkg --print-architecture 2>/dev/null || true)
    if [[ "$os_id" == ubuntu && "$os_version" == '24.04' && "$os_codename" == noble && "$architecture" == amd64 ]]; then
        report PASS cp4-os "Ubuntu $os_version ($os_codename), $architecture"
    else
        report MISSING cp4-os "requires Ubuntu 24.04 Noble amd64; found $os_id $os_version $os_codename $architecture"
    fi
    if detect_network_interfaces && verify_network_state; then
        report PASS cp4-cp2 'CP2 underlay and bridged networking are ready'
    else
        report MISSING cp4-cp2 'CP2 network state is not ready'
    fi
    if admin_firewall_is_ready && systemctl is-active --quiet "wg-quick@$WG_INTERFACE.service" &&
       [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)" == '1' ]]; then
        report PASS cp4-cp3 'CP3 WireGuard, loaded nftables policy and forwarding are ready'
    else
        report MISSING cp4-cp3 'CP3 state is not ready; CP4 will not change the VPN or its firewall'
    fi
    for package in docker-ce docker-ce-cli containerd.io docker-compose-plugin; do
        case "$package" in
            docker-ce|docker-ce-cli) expected="$DOCKER_CE_VERSION" ;;
            containerd.io) expected="$CONTAINERD_IO_VERSION" ;;
            docker-compose-plugin) expected="$DOCKER_COMPOSE_VERSION" ;;
        esac
        actual=$(docker_package_version "$package" || true)
        if [[ "$actual" == "$expected" ]]; then
            report PASS "docker-package:$package" "$actual"
        else
            report MISSING "docker-package:$package" "expected $expected; found ${actual:-not-installed}"
        fi
    done
    actual=$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)
    if systemctl is-enabled --quiet docker.service && systemctl is-active --quiet docker.service && [[ "$actual" == '29.8.1' ]]; then
        report PASS docker-engine "service is enabled; daemon version=$actual"
    else
        report MISSING docker-engine "expected enabled Docker Engine 29.8.1; daemon reports ${actual:-unavailable}"
    fi
    actual=$(docker compose version 2>/dev/null || true)
    if [[ "$actual" == *'v5.5.1'* ]]; then
        report PASS docker-compose 'pinned 5.5.1 plugin responds'
    else
        report MISSING docker-compose "expected Compose 5.5.1; found ${actual:-unavailable}"
    fi
    docker_storage_check
    docker_group_check
    if docker_firewall_is_ready; then
        report PASS docker-forwarding 'systemd ordering and DOCKER-USER rules preserve only CP3 VPN-to-underlay forwarding'
    else
        report MISSING docker-forwarding 'Docker firewall integration is not ready; CP3 forwarding cannot be assumed'
    fi
    if docker_runtime_files_are_ready; then
        report PASS docker-runtime-files 'root-owned Compose catalog and placeholder template match their managed hashes'
        if docker compose -f "$DOCKER_RUNTIME_DIR/compose.yml" --env-file "$DOCKER_RUNTIME_DIR/.env.example" config --quiet >/dev/null 2>&1; then
            report PASS docker-compose-config 'catalog syntax resolves using placeholders only'
        else
            report MISSING docker-compose-config 'runtime catalog failed Compose validation'
        fi
    else
        report MISSING docker-runtime-files 'managed runtime files are absent, changed or have unsafe ownership/mode'
    fi
    docker_app_diagnostics
}

install_docker_firewall_integration() (
    local script_tmp unit_tmp dropin_tmp script_content unit_content dropin_content path
    script_content=$(cat <<'EOF'
#!/usr/bin/env bash
# Managed by PowerSeven CP4
set -euo pipefail
ensure_first() {
    local chain="$1"; shift
    while iptables -w -C "$chain" "$@" >/dev/null 2>&1; do
        iptables -w -D "$chain" "$@"
    done
    iptables -w -I "$chain" 1 "$@"
}
iptables -w -N DOCKER-USER 2>/dev/null || true
ensure_first DOCKER-USER -i wg-admin -s 10.99.0.0/24 -d 192.168.214.0/24 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
ensure_first DOCKER-USER -o wg-admin -s 192.168.214.0/24 -d 10.99.0.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ensure_first FORWARD -j DOCKER-USER
EOF
)
    unit_content=$(cat <<'EOF'
[Unit]
Description=PowerSeven Docker forwarding integration
Requires=powerseven-admin-firewall.service
After=powerseven-admin-firewall.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/lib/powerseven/apply-docker-user-firewall.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)
    dropin_content=$(cat <<'EOF'
[Unit]
Requires=powerseven-admin-firewall.service powerseven-docker-firewall.service
After=powerseven-admin-firewall.service powerseven-docker-firewall.service
EOF
)
    for path in "$DOCKER_FIREWALL_SCRIPT" "/etc/systemd/system/$DOCKER_FIREWALL_UNIT" "$DOCKER_FIREWALL_DROPIN"; do
        if [[ -e "$path" ]] && ! grep -Fq '# Managed by PowerSeven CP4' "$path"; then
            report FAIL docker-forwarding "refusing to overwrite unmanaged file $path"
            return 1
        fi
    done
    install -d -o root -g root -m 0755 /usr/local/lib/powerseven /etc/systemd/system/docker.service.d
    script_tmp=$(mktemp /usr/local/lib/powerseven/.docker-firewall.XXXXXX)
    unit_tmp=$(mktemp "/etc/systemd/system/.$DOCKER_FIREWALL_UNIT.XXXXXX")
    dropin_tmp=$(mktemp /etc/systemd/system/docker.service.d/.powerseven-firewall.XXXXXX)
    {
        printf '%s\n' "$script_content"
    } > "$script_tmp"
    {
        printf '%s\n' '# Managed by PowerSeven CP4'
        printf '%s\n' "$unit_content"
    } > "$unit_tmp"
    {
        printf '%s\n' '# Managed by PowerSeven CP4'
        printf '%s\n' "$dropin_content"
    } > "$dropin_tmp"
    install -o root -g root -m 0755 "$script_tmp" "$DOCKER_FIREWALL_SCRIPT"
    install -o root -g root -m 0644 "$unit_tmp" "/etc/systemd/system/$DOCKER_FIREWALL_UNIT"
    install -o root -g root -m 0644 "$dropin_tmp" "$DOCKER_FIREWALL_DROPIN"
    rm -f "$script_tmp" "$unit_tmp" "$dropin_tmp"
    systemctl daemon-reload
    systemctl enable "$DOCKER_FIREWALL_UNIT"
    systemctl restart "$DOCKER_FIREWALL_UNIT"
)

docker_checkpoint() {
    local os_id os_version os_codename architecture package installed source_tmp key_tmp stage manifest old_hash new_hash new_env_hash actual path
    local compose_source compose_runtime env_source env_runtime
    local -a packages=(docker-ce docker-ce-cli containerd.io docker-compose-plugin docker.io docker-compose docker-compose-v2 docker-doc docker-buildx containerd runc podman-docker)
    if [[ "$MODE" == check ]]; then
        docker_foundation_check
        return 0
    fi
    [[ "$EUID" -eq 0 ]] || { report FAIL privileges 'CP4 apply requires root'; return 1; }
    [[ "$RUNTIME_STAGE_ID" =~ ^[a-f0-9]{32}$ ]] || { report FAIL arguments 'CP4 apply requires a valid runtime staging token'; return 1; }
    stage="/tmp/powerseven-cp4-$RUNTIME_STAGE_ID"
    compose_source="$stage/compose.yml"
    env_source="$stage/.env.example"
    [[ -s "$compose_source" && -s "$env_source" ]] || { report FAIL docker-stage 'Compose catalog or environment template is missing from secure staging'; return 1; }
    os_id=$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    os_version=$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    os_codename=$(awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2; exit }' /etc/os-release 2>/dev/null || true)
    architecture=$(dpkg --print-architecture 2>/dev/null || true)
    if [[ "$os_id" != ubuntu || "$os_version" != '24.04' || "$os_codename" != noble || "$architecture" != amd64 ]]; then
        report FAIL cp4-os "requires Ubuntu 24.04 Noble amd64; found $os_id $os_version $os_codename $architecture"
        return 1
    fi
    if ! detect_network_interfaces || ! verify_network_state; then
        report FAIL cp4-cp2 'CP4 requires the validated CP2 static underlay and bridged DHCP state'
        return 1
    fi
    if ! admin_firewall_is_ready || ! systemctl is-active --quiet "wg-quick@$WG_INTERFACE.service" ||
       [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || printf 0)" != '1' ]]; then
        report FAIL cp4-cp3 'CP4 requires the validated CP3 firewall, WireGuard interface and IPv4 forwarding'
        return 1
    fi
    if ! require_commands apt-get dpkg-query systemctl ip sha256sum install mktemp stat find timeout ss getent findmnt df; then return 1; fi
    installed=$(getent group docker 2>/dev/null | awk -F: '{ print $4 }' || true)
    if [[ -n "$installed" ]]; then
        report FAIL docker-group 'Docker group already has members; CP4 will not grant, remove or change root-equivalent membership'
        return 1
    fi
    for package in "${packages[@]}"; do
        installed=$(docker_package_version "$package" || true)
        case "$package" in
            docker-ce|docker-ce-cli) [[ -z "$installed" || "$installed" == "$DOCKER_CE_VERSION" ]] || { report FAIL docker-package "existing $package version $installed differs from the pinned target; preserving existing engine/data"; return 1; } ;;
            containerd.io) [[ -z "$installed" || "$installed" == "$CONTAINERD_IO_VERSION" ]] || { report FAIL docker-package "existing $package version $installed differs from the pinned target; preserving existing engine/data"; return 1; } ;;
            docker-compose-plugin) [[ -z "$installed" || "$installed" == "$DOCKER_COMPOSE_VERSION" ]] || { report FAIL docker-package "existing $package version $installed differs from the pinned target"; return 1; } ;;
            *) [[ -z "$installed" ]] || { report FAIL docker-package "conflicting package $package is installed; no package was removed"; return 1; } ;;
        esac
    done
    if [[ -z "$(docker_package_version docker-ce || true)" ]]; then
        for path in /var/lib/docker /var/lib/containerd; do
            if [[ -d "$path" ]] && find "$path" -mindepth 1 -print -quit | grep -q .; then
                report FAIL docker-data "unmanaged persistent data exists at $path; preserving it and refusing a fresh engine install"
                return 1
            fi
        done
    fi
    if [[ -e /etc/apt/sources.list.d/docker.sources ]] &&
       ! grep -Fxq 'URIs: https://download.docker.com/linux/ubuntu' /etc/apt/sources.list.d/docker.sources; then
        report FAIL docker-repository 'existing Docker APT source is unmanaged; preserving it'
        return 1
    fi
    for path in "$DOCKER_FIREWALL_SCRIPT" "/etc/systemd/system/$DOCKER_FIREWALL_UNIT" "$DOCKER_FIREWALL_DROPIN"; do
        if [[ -e "$path" ]] && ! grep -Fq '# Managed by PowerSeven CP4' "$path"; then
            report FAIL docker-forwarding "refusing to overwrite unmanaged file $path"
            return 1
        fi
    done
    if [[ -e /opt/powerseven && "$(stat -c '%U:%G:%a' /opt/powerseven)" != 'root:root:755' ]]; then
        report FAIL docker-runtime-files 'existing /opt/powerseven has unmanaged ownership or mode; preserving it'
        return 1
    fi
    manifest="$DOCKER_RUNTIME_DIR/.powerseven-managed-sha256"
    compose_runtime="$DOCKER_RUNTIME_DIR/compose.yml"
    env_runtime="$DOCKER_RUNTIME_DIR/.env.example"
    new_hash=$(sha256sum "$compose_source" | awk '{ print $1 }')
    new_env_hash=$(sha256sum "$env_source" | awk '{ print $1 }')
    [[ "$new_hash" =~ ^[a-f0-9]{64}$ && "$new_env_hash" =~ ^[a-f0-9]{64}$ ]] || { report FAIL docker-stage 'runtime payload checksum is invalid'; return 1; }
    if [[ -e "$compose_runtime" || -e "$env_runtime" || -e "$manifest" ]]; then
        for path in "$compose_runtime" "$env_runtime" "$manifest"; do
            if [[ -e "$path" && "$(stat -c '%U:%G:%a' "$path")" != 'root:root:644' ]]; then
                report FAIL docker-runtime-files "refusing to adopt unmanaged ownership/mode for $path"
                return 1
            fi
        done
        for pair in "compose.yml:$compose_runtime:$compose_source" ".env.example:$env_runtime:$env_source"; do
            name=${pair%%:*}; path=${pair#*:}; path=${path%%:*}; source_tmp=${pair##*:}
            old_hash=''
            [[ -f "$manifest" ]] && old_hash=$(awk -v name="$name" '$1 == name { print $2; exit }' "$manifest")
            actual=$(sha256sum "$path" 2>/dev/null | awk '{ print $1 }' || true)
            installed=$(sha256sum "$source_tmp" | awk '{ print $1 }')
            if [[ -n "$actual" && "$actual" != "$installed" && ( -z "$old_hash" || "$actual" != "$old_hash" ) ]]; then
                report FAIL docker-runtime-files "unmanaged or edited file $path was found; preserving it"
                return 1
            fi
            if [[ -e "$manifest" && -z "$old_hash" ]]; then
                report FAIL docker-runtime-files "managed manifest has no entry for $name; preserving existing state"
                return 1
            fi
        done
    fi
    install -d -o root -g root -m 0755 /opt/powerseven "$DOCKER_RUNTIME_DIR"
    install -o root -g root -m 0644 "$compose_source" "$compose_runtime.new"
    install -o root -g root -m 0644 "$env_source" "$env_runtime.new"
    mv -f "$compose_runtime.new" "$compose_runtime"
    mv -f "$env_runtime.new" "$env_runtime"
    {
        sha256sum "$compose_runtime" | awk '{ print "compose.yml", $1 }'
        sha256sum "$env_runtime" | awk '{ print ".env.example", $1 }'
    } > "$manifest.new"
    chmod 0644 "$manifest.new"
    mv -f "$manifest.new" "$manifest"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl iptables
    if ! require_commands curl iptables; then return 1; fi
    if ! grep -q 'nf_tables' <<< "$(iptables --version 2>/dev/null || true)"; then
        report FAIL docker-forwarding 'Ubuntu iptables must use its nftables compatibility backend; no firewall backend was changed'
        return 1
    fi
    install -d -o root -g root -m 0755 /etc/apt/keyrings
    key_tmp=$(mktemp /etc/apt/keyrings/.docker.asc.XXXXXX)
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$key_tmp"
    if [[ -e /etc/apt/keyrings/docker.asc ]] && ! cmp -s "$key_tmp" /etc/apt/keyrings/docker.asc; then
        rm -f "$key_tmp"
        report FAIL docker-repository 'existing Docker APT signing key differs from the official key; preserving it'
        return 1
    fi
    install -o root -g root -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc
    rm -f "$key_tmp"
    source_tmp=$(mktemp /etc/apt/sources.list.d/.docker.sources.XXXXXX)
    cat > "$source_tmp" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    if [[ -e /etc/apt/sources.list.d/docker.sources ]] && ! cmp -s "$source_tmp" /etc/apt/sources.list.d/docker.sources; then
        rm -f "$source_tmp"
        report FAIL docker-repository 'existing Docker APT source differs from the managed Noble source; preserving it'
        return 1
    fi
    install -o root -g root -m 0644 "$source_tmp" /etc/apt/sources.list.d/docker.sources
    rm -f "$source_tmp"
    install_docker_firewall_integration
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "docker-ce=$DOCKER_CE_VERSION" "docker-ce-cli=$DOCKER_CE_VERSION" \
        "containerd.io=$CONTAINERD_IO_VERSION" "docker-compose-plugin=$DOCKER_COMPOSE_VERSION"
    systemctl enable --now containerd.service
    "$DOCKER_FIREWALL_SCRIPT"
    systemctl enable --now docker.service
    docker_firewall_is_ready || { report FAIL docker-forwarding 'managed Docker forwarding rules did not remain active'; return 1; }
    docker_runtime_files_are_ready || { report FAIL docker-runtime-files 'runtime files failed ownership/checksum validation'; return 1; }
    [[ -z "$(getent group docker 2>/dev/null | awk -F: '{ print $4 }' || true)" ]] || { report FAIL docker-group 'Docker group membership changed during install; no member was removed'; return 1; }
    [[ "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)" == '/var/lib/docker' ]] || { report FAIL docker-storage 'Docker data root differs from persistent default /var/lib/docker'; return 1; }
    docker_storage_check
    docker_group_check
    docker compose -f "$DOCKER_RUNTIME_DIR/compose.yml" --env-file "$DOCKER_RUNTIME_DIR/.env.example" config --quiet
    report PASS cp4-foundation 'pinned Docker Engine/Compose, root-owned runtime catalog and CP3 forwarding integration are ready'
    report INFO cp4-applications 'Compose containers were not started; unresolved image pins, DB/LDAP configuration and secrets require the next application milestone'
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
            [[ $# -ge 2 ]] || { report FAIL arguments '--cleanup-client requires a peer'; exit 2; }
            CLEANUP_CLIENT="$2"
            shift 2
            ;;
        --peer-list)
            [[ $# -ge 2 ]] || { report FAIL arguments '--peer-list requires names'; exit 2; }
            PEER_NAMES_CSV="$2"
            shift 2
            ;;
        --runtime-token)
            [[ $# -ge 2 ]] || { report FAIL arguments '--runtime-token requires a value'; exit 2; }
            RUNTIME_STAGE_ID="$2"
            shift 2
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
if [[ "$CHECKPOINT" != '1' && "$CHECKPOINT" != '2' && "$CHECKPOINT" != '3' && "$CHECKPOINT" != '4' ]]; then
    report FAIL "checkpoint$CHECKPOINT" 'only checkpoints 1, 2, 3 and 4 are implemented'
    exit 2
fi
if [[ "$CHECKPOINT" == '1' && ( -n "$NETWORK_TRANSACTION_ID" || -n "$CONFIRM_NETWORK_TRANSACTION_ID" || -n "$CLEANUP_CLIENT" || -n "$PEER_NAMES_CSV" || -n "$RUNTIME_STAGE_ID" ) ]]; then
    report FAIL arguments 'network/client/runtime options are valid only for their matching checkpoints'
    exit 2
fi
if [[ "$CHECKPOINT" == '2' && ( -n "$CLEANUP_CLIENT" || -n "$PEER_NAMES_CSV" ) ]]; then
    report FAIL arguments 'peer options are valid only for checkpoint 3'
    exit 2
fi
if [[ "$CHECKPOINT" == '3' && ( -n "$NETWORK_TRANSACTION_ID" || -n "$CONFIRM_NETWORK_TRANSACTION_ID" ) ]]; then
    report FAIL arguments 'network transaction options are valid only for checkpoint 2'
    exit 2
fi
if [[ "$CHECKPOINT" != '4' && -n "$RUNTIME_STAGE_ID" ]]; then
    report FAIL arguments '--runtime-token is valid only for checkpoint 4'; exit 2
fi
if [[ "$CHECKPOINT" == '4' && ( -n "$NETWORK_TRANSACTION_ID" || -n "$CONFIRM_NETWORK_TRANSACTION_ID" || -n "$CLEANUP_CLIENT" || -n "$PEER_NAMES_CSV" ) ]]; then
    report FAIL arguments 'network/client options are invalid for checkpoint 4'; exit 2
fi
if [[ "$CHECKPOINT" == '4' && "$MODE" == 'apply' && ! "$RUNTIME_STAGE_ID" =~ ^[a-f0-9]{32}$ ]]; then
    report FAIL arguments 'checkpoint 4 apply requires a 32-character runtime token'; exit 2
fi
if [[ "$CHECKPOINT" == '4' && "$MODE" == 'check' && -n "$RUNTIME_STAGE_ID" ]]; then
    report FAIL arguments 'checkpoint 4 check does not accept a runtime token'; exit 2
fi
if [[ -n "$CLEANUP_CLIENT" && "$MODE" != 'apply' ]]; then
    report FAIL arguments '--cleanup-client requires --apply'; exit 2
fi
if [[ -n "$PEER_NAMES_CSV" && ( "$MODE" != 'apply' || -n "$CLEANUP_CLIENT" ) ]]; then
    report FAIL arguments '--peer-list requires CP3 apply without cleanup'; exit 2
fi
if [[ -n "$CLEANUP_CLIENT" && ! "$CLEANUP_CLIENT" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    report FAIL arguments 'invalid admin VPN peer name'; exit 2
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
    4)
        docker_checkpoint
        if [[ "$MODE" == 'check' ]] && (( CHECK_NEEDS_APPLY )); then exit 1; fi
        ;;
esac
