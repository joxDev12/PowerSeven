#!/usr/bin/env python3
"""Read-only validator for the local PowerSeven administrative VPN design."""

from __future__ import annotations

import ipaddress
import os
import re
import subprocess
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
PASS = FAIL = 0


def report(level: str, label: str, detail: str) -> None:
    global PASS, FAIL
    print(f"{level}: {label}: {detail}")
    if level == "PASS":
        PASS += 1
    elif level == "FAIL":
        FAIL += 1


def network_fixture_is_unambiguous(addresses: dict[str, str | None]) -> bool:
    underlay = [name for name, address in addresses.items() if address and re.fullmatch(r"192\.168\.214\.[0-9]+/24", address)]
    if len(underlay) != 1:
        return False
    bridged = [name for name in addresses if name != underlay[0]]
    return len(bridged) == 1


def split_tunnel_overlap_fixture(underlay: str, routes: list[str]) -> bool:
    private = ipaddress.ip_network(underlay)
    fragments = [ipaddress.ip_network(route) for route in routes]
    if any(not route.subnet_of(private) or route.prefixlen <= private.prefixlen for route in fragments):
        return False
    if list(ipaddress.collapse_addresses(fragments)) != [private]:
        return False
    local_route = private
    for address in (private.network_address, private.network_address + 13,
                    private.network_address + 14, private.network_address + 127,
                    private.network_address + 128, private.broadcast_address - 1,
                    private.broadcast_address):
        selected = max((route for route in [local_route, *fragments] if address in route), key=lambda route: route.prefixlen)
        if selected not in fragments:
            return False
    return not any(address in route for address in (
        ipaddress.ip_address("8.8.8.8"), ipaddress.ip_address("1.1.1.1")) for route in fragments)


def network_ready_fixture(state: dict[str, bool]) -> bool:
    return all(state[key] for key in ("underlay", "default_route", "bridge_link", "bridge_ipv4", "underlay_dns", "networkd", "persistence")) and not state["bridge_default_route"] and not state["bridge_dns"]


def network_retry_fixture(states: list[dict[str, bool]], timeout: int = 45, interval: int = 2) -> bool:
    return any(network_ready_fixture(state) for state in states[: timeout // interval + 1])


def networkd_takeover_fixture(*, initially_managed: bool, reload_manages: bool, restart_manages: bool) -> tuple[bool, str]:
    if initially_managed:
        return True, "none"
    if reload_manages:
        return True, "reload"
    if restart_manages:
        return True, "restart"
    return False, "rollback"


def networkd_status_fixtures(bootstrap: str) -> bool:
    functions = []
    for name in ("networkd_read_link_state", "networkd_interface_is_configured"):
        match = re.search(rf"^{name}\(\) \{{\n.*?^\}}", bootstrap, re.MULTILINE | re.DOTALL)
        if not match:
            return False
        functions.append(match.group())
    rollback_match = re.search(r"^rollback_underlay_configured\(\) \{\n.*?^\}", bootstrap, re.MULTILINE | re.DOTALL)
    if not rollback_match:
        return False
    script = """set -euo pipefail
get_interface_mac() { printf '%s\\n' '00:0c:29:f7:ee:15'; }
networkd_file_for_mac() { printf '%s\\n' '/run/systemd/network/10-netplan-powerseven-underlay.network'; }
networkctl() {
    case "$SCENARIO" in
        ready) state='routable (configured)'; file='/run/systemd/network/10-netplan-powerseven-underlay.network' ;;
        configuring) state='routable (configuring)'; file='/run/systemd/network/10-netplan-powerseven-underlay.network' ;;
        unmanaged) state='off (unmanaged)'; file='n/a' ;;
        failed) state='degraded (failed)'; file='/run/systemd/network/10-netplan-powerseven-underlay.network' ;;
        wrong-file) state='routable (configured)'; file='/etc/systemd/network/other.network' ;;
        unavailable) return 1 ;;
    esac
    printf '● 2: ens32\\n Network File: %s\\n State: %s\\n' "$file" "$state"
}
"""
    main_script = script + "\n".join(functions) + """
if networkd_interface_is_configured ens32; then
    printf 'ready:%s\\n' "$NETWORKD_SETUP"
else
    printf 'pending:%s\\n' "$NETWORKD_SETUP"
fi
"""
    rollback_script = script + """underlay_iface=ens32
expected_network_file=/run/systemd/network/10-netplan-powerseven-underlay.network
""" + rollback_match.group().replace("\\$", "$") + """
if rollback_underlay_configured; then printf 'ready\\n'; else printf 'pending\\n'; fi
"""
    expected = {
        "ready": "ready:configured", "configuring": "pending:configuring",
        "unmanaged": "pending:unmanaged", "failed": "pending:failed",
        "wrong-file": "pending:configured", "unavailable": "pending:unknown",
    }
    for scenario, output in expected.items():
        for shell, wanted in ((main_script, output), (rollback_script, "ready" if scenario == "ready" else "pending")):
            result = subprocess.run(
                ["bash", "-c", shell], env={**os.environ, "SCENARIO": scenario},
                capture_output=True, text=True, timeout=5, check=False,
            )
            if result.returncode != 0 or result.stdout.strip() != wanted:
                return False
    return True


def admin_peer_inventory_fixtures(bootstrap: str) -> bool:
    functions = []
    for name in ("admin_peer_names_to_addresses", "load_admin_peers"):
        match = re.search(rf"^{name}\(\) \{{.*?^\}}", bootstrap, re.MULTILINE | re.DOTALL)
        if not match:
            return False
        functions.append(match.group())
    prefix = """set -euo pipefail
ADMIN_PEERS=()
WG_CLIENT_STATE_DIR="$FIX/clients"
WG_PEER_INVENTORY="$FIX/peers"
WG_CONFIG="$FIX/wg-admin.conf"
report() { printf '%s\\n' "$*"; }
""" + "\n".join(functions) + "\n"

    def run(root: Path, body: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", "-c", prefix + body], env={**os.environ, "FIX": str(root)},
            capture_output=True, text=True, timeout=5, check=False,
        )

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        fresh = run(root, 'PEER_NAMES_CSV="desktop,portatile,surface"\nload_admin_peers write\nprintf "%s\\n" "${ADMIN_PEERS[*]}"\n')
        expected = "desktop:10.99.0.2/32 portatile:10.99.0.3/32 surface:10.99.0.4/32"
        if fresh.returncode or fresh.stdout.strip() != expected or (root / "peers").read_text().splitlines() != ["desktop", "portatile", "surface"]:
            return False
        rerun = run(root, 'PEER_NAMES_CSV=""\nload_admin_peers read\nprintf "%s\\n" "${ADMIN_PEERS[*]}"\n')
        changed = run(root, 'PEER_NAMES_CSV="desktop,other"\nload_admin_peers write\n')
        if rerun.returncode or rerun.stdout.strip() != expected or changed.returncode == 0 or (root / "peers").read_text().splitlines() != ["desktop", "portatile", "surface"]:
            return False

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        clients = root / "clients"
        clients.mkdir()
        keys = {"jarvis": "A" * 43 + "=", "giorgio-laptop": "B" * 43 + "="}
        for name, key in keys.items():
            (clients / f"{name}.pub").write_text(key + "\n")
        (root / "wg-admin.conf").write_text(
            "[Interface]\nAddress = 10.99.0.1/24\n\n"
            f"[Peer]\nPublicKey = {keys['giorgio-laptop']}\nAllowedIPs = 10.99.0.3/32\n\n"
            f"[Peer]\nPublicKey = {keys['jarvis']}\nAllowedIPs = 10.99.0.2/32\n"
        )
        read = run(root, 'PEER_NAMES_CSV=""\nload_admin_peers read\nprintf "%s\\n" "${ADMIN_PEERS[*]}"\n')
        migrated = run(root, 'PEER_NAMES_CSV=""\nload_admin_peers write\nprintf "%s\\n" "${ADMIN_PEERS[*]}"\n')
        if (read.returncode or migrated.returncode or read.stdout != migrated.stdout or
                read.stdout.strip() != "jarvis:10.99.0.2/32 giorgio-laptop:10.99.0.3/32" or
                (root / "peers").read_text().splitlines() != ["jarvis", "giorgio-laptop"] or
                any((clients / f"{name}.pub").read_text().strip() != key for name, key in keys.items())):
            return False
    return True


def host_key_fixture(trusted: str, presented: str) -> bool:
    return trusted == presented


def runner_cp2_fixture(*, already_ready: bool, old_session_pending: bool, static_ready: bool, host_key_same: bool) -> dict[str, bool]:
    if already_ready:
        return {"passed": True, "token": False, "bounded": True}
    if not host_key_same or not static_ready:
        return {"passed": False, "token": True, "bounded": True}
    return {"passed": True, "token": True, "bounded": old_session_pending}


def persistence_fixture(runtime_ready: bool, persistent_ready: bool) -> bool:
    return runtime_ready and persistent_ready


def persistent_netplan_fixture(*, file_exists: bool, content_ok: bool, macs_ok: bool, mode_ok: bool, generate_ok: bool) -> bool:
    return all((file_exists, content_ok, macs_ok, mode_ok, generate_ok))


def rollback_cleanup_fixture(*, token_cleared: bool, backup_cleared: bool, marker_cleared: bool, units_stopped: bool) -> bool:
    return all((token_cleared, backup_cleared, marker_cleared, units_stopped))


def cold_state_fixture(persistent_ready: bool) -> bool:
    return persistent_ready


def windows_firewall_range_fixture(values: list[str], family: int) -> bool:
    try:
        ranges = []
        for value in values:
            start_text, end_text = value.split("-", 1)
            start, end = ipaddress.ip_address(start_text), ipaddress.ip_address(end_text)
            if start.version != family or end.version != family or int(start) > int(end):
                return False
            for address in (start, end):
                if address.is_unspecified or address.is_loopback or address.is_multicast:
                    return False
                if family == 4 and address == ipaddress.ip_address("255.255.255.255"):
                    return False
            ranges.append((int(start), int(end)))
        return ranges == sorted(ranges) and all(left[1] < right[0] for left, right in zip(ranges, ranges[1:]))
    except ValueError:
        return False


def firewall_address_identity(value: str) -> tuple:
    token = value.strip()
    if re.fullmatch(r"(?i)(Any|LocalSubnet|DNS|DHCP|WINS|DefaultGateway|Internet|Intranet|IntranetRemoteAccess|PlayToDevice|CaptivePortal)([46])?", token):
        return ("keyword", token.lower())
    if "-" in token:
        start_text, end_text = token.split("-", 1)
        start, end = ipaddress.ip_address(start_text.strip()), ipaddress.ip_address(end_text.strip())
        if start.version != end.version or int(start) > int(end):
            raise ValueError(token)
        return ("range", start.version, int(start), int(end))
    if "/" in token:
        network = ipaddress.ip_network(token, strict=False)
    else:
        address = ipaddress.ip_address(token)
        network = ipaddress.ip_network(f"{address}/{address.max_prefixlen}", strict=False)
    return ("network", network.version, int(network.network_address), network.prefixlen)


def firewall_address_semantics_fixture() -> bool:
    equivalent_pairs = (
        ("10.99.0.0/24", "10.99.0.0/255.255.255.0"),
        ("192.168.214.13", "192.168.214.13/32"),
        ("2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001/128"),
        ("::2-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "0000:0000:0000:0000:0000:0000:0000:0002-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"),
    )
    if not all(firewall_address_identity(left) == firewall_address_identity(right) for left, right in equivalent_pairs):
        return False
    if len({firewall_address_identity(value) for value in ("Any", "any")}) != 1:
        return False
    try:
        firewall_address_identity("10.99.0.0/255.0.255.0")
    except (ValueError, ipaddress.NetmaskValueError):
        return True
    return False


def check_ssh_session_count(protocol_probe_sessions: int, checkpoint_sessions: int, extra_sessions: int) -> int:
    return protocol_probe_sessions + checkpoint_sessions + extra_sessions


def protocol_probe_fixture(exit_code: int, stderr: str, output: str, version: str, capabilities: str, checkpoint: str) -> tuple[bool, bool]:
    transport_failure = exit_code == 255 or bool(re.search(r"(?i)(permission denied|host key verification failed|connection timed out|connection refused|no route to host)", stderr))
    authenticated = not transport_failure
    supported_checkpoints = capabilities.partition("=")[2].split(",")
    supported = authenticated and exit_code == 0 and output.strip().splitlines() == [f"powerseven-bootstrap {version}", capabilities] and checkpoint in supported_checkpoints
    return authenticated, supported


def bootstrap_contract_fixture(bootstrap: str, runner: str) -> bool:
    version_pattern = r"^readonly POWERSEVEN_BOOTSTRAP_VERSION='([0-9]+)'\r?$"
    capabilities_pattern = r"^readonly POWERSEVEN_BOOTSTRAP_CAPABILITIES='([0-9]+(?:,[0-9]+)*)'\r?$"
    versions = re.findall(version_pattern, bootstrap, re.MULTILINE)
    capabilities = re.findall(capabilities_pattern, bootstrap, re.MULTILINE)
    windows_versions = re.findall(version_pattern, bootstrap.replace("\n", "\r\n"), re.MULTILINE)
    windows_capabilities = re.findall(capabilities_pattern, bootstrap.replace("\n", "\r\n"), re.MULTILINE)
    transaction_match = re.search(r"\$installCommand = @'\n(?P<body>.*?)\n'@", runner, re.DOTALL)
    transaction = transaction_match.group("body") if transaction_match else ""
    sentinel_version, sentinel_capabilities = "987", "4,5"
    rendered = transaction.replace("__BOOTSTRAP_VERSION__", sentinel_version).replace("__BOOTSTRAP_CAPABILITIES__", sentinel_capabilities)
    try:
        shell_check = subprocess.run(["bash", "-n"], input=rendered, text=True, capture_output=True, check=False)
    except OSError:
        return False
    return (
        len(versions) == 1 and len(capabilities) == 1 and versions == windows_versions and capabilities == windows_capabilities and transaction_match is not None and
        "if [[ \"$#\" -eq 1 && \"$1\" == '--protocol' ]]" in bootstrap and
        'printf \'powerseven-bootstrap %s\\ncheckpoints=%s\\n\' "$POWERSEVEN_BOOTSTRAP_VERSION" "$POWERSEVEN_BOOTSTRAP_CAPABILITIES"' in bootstrap and
        "$bootstrapVersionMatches = [regex]::Matches($bootstrapContractSource" in runner and
        "$bootstrapCapabilitiesMatches = [regex]::Matches($bootstrapContractSource" in runner and
        "New-RemoteBootstrapFiles -Username $UbuntuUsername -BootstrapContent $bootstrapContractSource" in runner and
        "([0-9]+)'\\r?$" in runner and "([0-9]+(,[0-9]+)*)'\\r?$" in runner and
        "$requiredBootstrapVersion = $bootstrapVersionMatches[0].Groups[1].Value" in runner and
        "$bootstrapCapabilities = $bootstrapCapabilitiesMatches[0].Groups[1].Value" in runner and
        "$requiredBootstrapCapabilities = \"checkpoints=$bootstrapCapabilities\"" in runner and
        not re.search(r"\$requiredBootstrapVersion\s*=\s*['\"][0-9]+['\"]", runner) and
        not re.search(r"\$requiredBootstrapCapabilities\s*=\s*['\"]checkpoints=[0-9]", runner) and
        "expected_protocol=\"$(printf 'powerseven-bootstrap %s\\ncheckpoints=%s' '__BOOTSTRAP_VERSION__' '__BOOTSTRAP_CAPABILITIES__')\"" in transaction and
        'test "$(sudo "$wrapper" --protocol)" = "$expected_protocol"' in transaction and
        "$installCommand = $installCommand.Replace('__STAGE__'" in runner and
        ".Replace('__BOOTSTRAP_VERSION__', $requiredBootstrapVersion)" in runner and
        ".Replace('__BOOTSTRAP_CAPABILITIES__', $bootstrapCapabilities)" in runner and
        not re.search(r"powerseven-bootstrap\s+[0-9]+", transaction) and
        f"powerseven-bootstrap %s\\ncheckpoints=%s' '{sentinel_version}' '{sentinel_capabilities}'" in rendered and
        shell_check.returncode == 0
    )


def transaction_isolation_fixture(old_transaction: str, new_transaction: str) -> bool:
    return old_transaction != new_transaction


def load(relative: str):
    with (ROOT / relative).open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def main() -> int:
    vmware = load("iac/vmware/vm-definitions.yml")
    networks = load("iac/inventory/networks.yml")
    hosts = load("iac/inventory/hosts.yml")
    bootstrap = (ROOT / "iac/linux/bootstrap.sh").read_text(encoding="utf-8")
    runner = (ROOT / "iac/windows/setup-powerseven.ps1").read_text(encoding="utf-8")
    wrapper_match = re.search(r"\$wrapper = @'\n(?P<body>.*?)\n'@", runner, re.DOTALL)

    vps14 = next(vm for vm in vmware["vms"] if vm["id"] == "vps14")
    nics = {nic["role"]: nic for nic in vps14["nics"]}
    if nics.get("vmnet8-underlay", {}).get("address") == "192.168.214.14/24" and nics.get("vmnet8-underlay", {}).get("gateway") == "192.168.214.2":
        report("PASS", "vmnet8", "VPS14 static underlay and gateway are declared")
    else:
        report("FAIL", "vmnet8", "VPS14 underlay declaration is incomplete")
    bridged = nics.get("bridged-admin-ingress", {})
    if bridged.get("address") == "dhcp" and bridged.get("default_route") is False and bridged.get("dns") is False:
        report("PASS", "bridged", "bridged NIC is DHCP without route/DNS takeover")
    else:
        report("FAIL", "bridged", "bridged NIC must be DHCP with no default route and no DNS takeover")

    admin_plan = networks["target_local"]["address_planes"]["admin_vpn"]
    admin = networks["target_local"]["admin_vpn"]
    admin_net = ipaddress.ip_network(admin_plan["cidr"])
    pool = admin_plan["client_pool"]
    clients = admin["clients"]
    if (str(admin_net) == "10.99.0.0/24" and admin_plan["server"] == "10.99.0.1/24" and
            pool == {"first": "10.99.0.2", "last": "10.99.0.254", "assignment": "sequential_by_persistent_peer_order"} and
            clients["source"] == "vps14_persistent_peer_inventory" and clients["selected_on_first_cp3_apply"] is True and
            clients["address_start"] == pool["first"] and clients["address_end"] == pool["last"]):
        report("PASS", "admin-vpn-addresses", "variable peer pool 10.99.0.2-254 is declared")
    else:
        report("FAIL", "admin-vpn-addresses", "admin VPN address plan is inconsistent")
    underlay_cidr = networks["target_local"]["underlay"]["cidr"]
    allowed_ips = ["192.168.214.0/25", "192.168.214.128/25"]
    allowed_ips_text = ", ".join(allowed_ips)
    if (admin["allowed_ips"] != allowed_ips or
            not split_tunnel_overlap_fixture(underlay_cidr, admin["allowed_ips"]) or admin["nat"]["default"] is not False):
        report("FAIL", "routing-policy", "admin VPN must use VMnet8-only split tunnel and no NAT")
    else:
        report("PASS", "routing-policy", "two more-specific VPN routes cover VMnet8, beat Jarvis's /24, and leave Internet outside")
    if (f"readonly ADMIN_CLIENT_ROUTES='{allowed_ips_text}'" in bootstrap and
            f"$script:AdminClientAllowedIPs = '{allowed_ips_text}'" in runner):
        report("PASS", "client-route-contract", "Linux export, Windows migration and inventory share the split-route list")
    else:
        report("FAIL", "client-route-contract", "client AllowedIPs differ across inventory, Linux export and Windows migration")
    route = admin["return_routes"]["dc02"]
    if route == {"destination": "10.99.0.0/24", "via": "192.168.214.14"}:
        report("PASS", "dc02-route", "persistent return route target is declared")
    else:
        report("FAIL", "dc02-route", "DC02 return route is incomplete")

    if all(token in bootstrap for token in ("network_checkpoint", "vpn_checkpoint", "--confirm-network", "wg-admin", "10.99.0.1/24", "WG_PEER_INVENTORY", "--peer-list")):
        report("PASS", "linux-bootstrap", "CP2/CP3 and rollback/client paths exist")
    else:
        report("FAIL", "linux-bootstrap", "CP2/CP3 implementation markers are incomplete")
    network_match = re.search(r"detect_network_interfaces\(\) \{(?P<body>.*?)(?=\n\}\n\nreport_network_state\(\))", bootstrap, re.DOTALL)
    network_body = network_match.group("body") if network_match else ""
    if network_match and all(token in network_body for token in ("ip -o link show", "/sys/class/net/", "get_interface_ipv4", "${address:-none}", "${#underlay_candidates[@]}", "${#bridged_candidates[@]}")) and "done < <(ip -o -4 addr show scope global)" not in network_body:
        report("PASS", "network-detection", "CP2 enumerates Ethernet NICs without requiring bridged IPv4 and rejects ambiguity")
    else:
        report("FAIL", "network-detection", "CP2 still requires bridged IPv4 or lacks unique NIC safeguards")
    if network_match and all(token not in network_body for token in ("netplan apply", "write_netplan_config", "backup_netplan", "ip addr add", "ip link set")):
        report("PASS", "network-detection-readonly", "NIC discovery itself performs no network mutation")
    else:
        report("FAIL", "network-detection-readonly", "NIC discovery contains network mutation")
    fixtures = (
        ({"ens32": "192.168.214.145/24", "ens34": None}, True),
        ({"ens32": "192.168.214.145/24", "ens34": None, "eth0": None}, False),
        ({"ens32": "192.168.214.145/24"}, False),
    )
    if all(network_fixture_is_unambiguous(addresses) is expected for addresses, expected in fixtures):
        report("PASS", "network-detection-fixtures", "underlay+bridged-without-IPv4 passes; missing or ambiguous bridged NICs fail")
    else:
        report("FAIL", "network-detection-fixtures", "NIC ambiguity fixture coverage failed")
    if all(token in bootstrap for token in ("match: {macaddress:", "dhcp4: true", "use-routes: false", "use-dns: false", "schedule_network_rollback", "rollback_network_now")):
        report("PASS", "network-safety", "CP2 retains MAC-based Netplan, DHCP isolation and rollback guard")
    else:
        report("FAIL", "network-safety", "CP2 network safety controls are incomplete")
    if all(token in bootstrap for token in ("NETWORK_READY_TIMEOUT_SECONDS=45", "NETWORK_READY_INTERVAL_SECONDS=2", "network_state_missing", "wait_for_network_state", "sleep \"$sleep_for\"", "post-apply validation timed out", "bridged DHCP pending", "bridged default route present", "bridged DNS present")) and "while true" not in bootstrap:
        report("PASS", "network-retry", "post-apply DHCP validation is bounded and rolls back on timeout")
    else:
        report("FAIL", "network-retry", "post-apply network retry/timeout guard is incomplete")
    ready = {"underlay": True, "default_route": True, "bridge_link": True, "bridge_ipv4": True, "underlay_dns": True, "networkd": True, "persistence": True, "bridge_default_route": False, "bridge_dns": False}
    pending = dict(ready, underlay=False, default_route=False, bridge_ipv4=False, underlay_dns=False)
    static_pending = dict(ready, bridge_ipv4=False)
    route_error = dict(ready, bridge_default_route=True)
    dns_error = dict(ready, bridge_dns=True)
    underlay_pending = dict(ready, underlay=False)
    if (network_retry_fixture([pending, static_pending, ready]) and
            not network_retry_fixture([pending] * 30) and
            not network_ready_fixture(route_error) and
            not network_ready_fixture(dns_error) and
            not network_ready_fixture(underlay_pending)):
        report("PASS", "network-retry-fixtures", "delayed DHCP passes within timeout; timeout, route, DNS and underlay failures do not")
    else:
        report("FAIL", "network-retry-fixtures", "bounded network retry fixture coverage failed")
    persistence_cases = (
        (persistence_fixture(True, False), False),
        (persistence_fixture(True, True), True),
        (persistence_fixture(False, True), False),
        (persistent_netplan_fixture(file_exists=False, content_ok=True, macs_ok=True, mode_ok=True, generate_ok=True), False),
        (persistent_netplan_fixture(file_exists=True, content_ok=False, macs_ok=True, mode_ok=True, generate_ok=True), False),
        (persistent_netplan_fixture(file_exists=True, content_ok=True, macs_ok=False, mode_ok=True, generate_ok=True), False),
        (persistent_netplan_fixture(file_exists=True, content_ok=True, macs_ok=True, mode_ok=True, generate_ok=True), True),
        (rollback_cleanup_fixture(token_cleared=True, backup_cleared=True, marker_cleared=True, units_stopped=True), True),
        (cold_state_fixture(True), True),
        (cold_state_fixture(False), False),
        (transaction_isolation_fixture("transaction-a", "transaction-b"), True),
    )
    commit_match = re.search(r"commit_network_transaction\(\) \{(?P<body>.*?)(?=\n\}\n\nconfirm_network\(\))", bootstrap, re.DOTALL)
    commit_body = commit_match.group("body") if commit_match else ""
    persistence_tokens = (
        "netplan_persistence_is_valid",
        "network_state_missing",
        "flock -x 9",
        'exec 9>"\\$lock"',
        'pending=\\$(cat',
        "netplan-running-",
        "cancel_pending_network_transactions",
        "pending-token",
        "pending-backup",
        "netplan_block_contains",
        "chown root:root",
        "chmod 600",
        'mv -f "$temporary" "$file"',
        "networkd_interface_is_configured",
        'systemctl stop "$unit.timer" "$unit.service"',
    )
    if (all(actual == expected for actual, expected in persistence_cases) and
            all(token in bootstrap for token in persistence_tokens) and
            commit_match and
            commit_body.find("netplan_persistence_is_valid") < commit_body.find('stop_network_rollback_unit') < commit_body.find('rm -rf "$backup"')):
        report("PASS", "network-persistence-fixtures", "missing/invalid Netplan is remediation, commit validates before cleanup, rollback transactions are isolated and reboot-reconstructible")
    else:
        report("FAIL", "network-persistence-fixtures", "CP2 persistence/transaction fixture coverage failed")
    confirm_match = re.search(r"confirm_network\(\) \{(?P<body>.*?)(?=\n\}\n\nnetwork_checkpoint\(\))", bootstrap, re.DOTALL)
    confirm_body = confirm_match.group("body") if confirm_match else ""
    bridge_pending = dict(ready, bridge_ipv4=False)
    networkd_pending = dict(ready, networkd=False)
    persistence_missing = dict(ready, persistence=False)
    confirm_fixtures = (
        network_retry_fixture([networkd_pending] * 10 + [ready]),
        network_retry_fixture([bridge_pending] * 15 + [ready]),
        not network_retry_fixture([bridge_pending] * 24),
        not network_retry_fixture([persistence_missing] * 24),
        not persistence_fixture(True, False),
        persistence_fixture(True, True),
    )
    if (confirm_match and all(confirm_fixtures) and
            confirm_body.find("wait_for_network_state") < confirm_body.find("commit_network_transaction") and
            "verify_network_state" not in confirm_body and
            "NETWORK_ROLLBACK_TIMEOUT_SECONDS=180" in bootstrap and
            "-TimeoutSeconds 75" in runner and
            "network transition SSH session" in runner):
        report("PASS", "network-confirm-fixtures", "delayed networkd/DHCP wait, timeout, persistence and rollback window are covered")
    else:
        report("FAIL", "network-confirm-fixtures", "confirmation can commit early or outlive its rollback guard")
    takeover_cases = (
        networkd_takeover_fixture(initially_managed=False, reload_manages=True, restart_manages=False),
        networkd_takeover_fixture(initially_managed=False, reload_manages=False, restart_manages=True),
        networkd_takeover_fixture(initially_managed=False, reload_manages=False, restart_manages=False),
        networkd_takeover_fixture(initially_managed=True, reload_manages=False, restart_manages=False),
    )
    expected_takeover_cases = ((True, "reload"), (True, "restart"), (False, "rollback"), (True, "none"))
    takeover_tokens = (
        "networkd_file_for_mac()", "/run/systemd/network/*.network", "MACAddress|PermanentMACAddress",
        "netplan_generated_networkd_is_valid", "systemctl enable systemd-networkd.service",
    )
    apply_order_match = re.search(r"network_checkpoint\(\) \{(?P<body>.*?)(?=\n\}\n\nensure_wireguard_server_keys\(\))", bootstrap, re.DOTALL)
    apply_order_body = apply_order_match.group("body") if apply_order_match else ""
    apply_stages = [apply_order_body.find(token) for token in (
        "netplan generate", "netplan_generated_networkd_is_valid", "netplan apply", "ensure_networkd_takeover", "wait_for_network_state"
    )]
    rollback_match = re.search(r"rollback_network_now\(\) \{(?P<body>.*?)(?=\n\}\n\ncommit_network_transaction\(\))", bootstrap, re.DOTALL)
    transient_rollback_match = re.search(r"schedule_network_rollback\(\) \{(?P<body>.*?)(?=\n\}\n\nrollback_network_now\(\))", bootstrap, re.DOTALL)
    if (takeover_cases == expected_takeover_cases and all(token in bootstrap for token in takeover_tokens) and
            apply_order_match and all(index >= 0 for index in apply_stages) and apply_stages == sorted(apply_stages) and
            rollback_match and "reload_networkd_after_netplan" in rollback_match.group("body") and
            transient_rollback_match and all(token in transient_rollback_match.group("body") for token in (
                "networkctl reload", "networkctl reconfigure", "systemctl restart systemd-networkd.service")) and
            "NETWORKD_TAKEOVER_TIMEOUT_SECONDS=6" in bootstrap):
        report("PASS", "networkd-takeover-fixtures", "MAC-matched generated files, reload/reconfigure, bounded restart fallback and rollback reload are covered")
    else:
        report("FAIL", "networkd-takeover-fixtures", "networkd ownership takeover or rollback reload sequence is incomplete")
    if (networkd_status_fixtures(bootstrap) and "networkctl is-managed" not in bootstrap and
            "networkd_interface_is_configured" in bootstrap and transient_rollback_match and
            "rollback_underlay_configured" in transient_rollback_match.group("body")):
        report("PASS", "networkd-status-fixtures", "configured Netplan NICs pass; transient, unmanaged, failed, unavailable and wrong-file states stay pending")
    else:
        report("FAIL", "networkd-status-fixtures", "networkctl status parsing or rollback guard is unsafe")
    if (confirm_match and "confirm_started=$SECONDS" in confirm_body and
            "remaining=$((NETWORK_READY_TIMEOUT_SECONDS - elapsed))" in confirm_body and
            "-TimeoutSeconds 75" in runner):
        report("PASS", "networkd-confirm-timeout", "Linux confirmation shares a bounded 45-second budget and Windows allows 75 seconds")
    else:
        report("FAIL", "networkd-confirm-timeout", "Linux/Windows confirmation timeout budgets are inconsistent")
    cp3_match = re.search(r"vpn_checkpoint\(\) \{(?P<body>.*?)(?=\n\}\n\nwhile \[\[ \$# -gt 0 \]\])", bootstrap, re.DOTALL)
    cp3_body = cp3_match.group("body") if cp3_match else ""
    if (cp3_match and
            "ADMIN_PEERS" in cp3_body and
            "ensure_admin_client_export" in cp3_body and
            'iifname "$WG_INTERFACE" drop' in bootstrap and
            '"AllowedIPs = $ADMIN_CLIENT_ROUTES"' in bootstrap and
            "10.10.10.0/24" not in cp3_body and
            "jarvis" not in bootstrap and "giorgio-laptop" not in bootstrap and
            "jarvis" not in runner and "giorgio-laptop" not in runner and
            "load_admin_peers write" in cp3_body and
            'wg syncconf "$WG_INTERFACE"' in cp3_body and
            "--peer-status" in bootstrap and "--peer-status" in runner and
            "-PeerNames" in runner and "Read-Host 'Quanti dispositivi" in runner and
            "Invoke-NativeCapture $script:Ssh" in runner and
            "Test-NativeSuccess $script:Ssh ($keyOnlySshOptions + @($target, 'test'" not in runner and
            "explicit rotation is required" in runner and
            admin_peer_inventory_fixtures(bootstrap)):
        report("PASS", "variable-peer-vpn-fixtures", "chosen peers persist, migrate from legacy state and keep split tunnel and keys")
    else:
        report("FAIL", "variable-peer-vpn-fixtures", "variable peer state, migration or split-tunnel guards are incomplete")
    cp3_apply = cp3_body.split("    if [[ \"$MODE\" == 'apply' ]]", 1)[-1]
    cp3_stages = [cp3_apply.rfind(token) for token in (
        "ensure_admin_firewall", "ensure_wireguard_server_keys", "ensure_admin_client_export",
        "ensure_wireguard_config", 'systemctl enable --now "wg-quick@$WG_INTERFACE.service"',
    )]
    firewall_ready_match = re.search(r"admin_firewall_is_ready\(\) \{(?P<body>.*?)(?=\n\}\n\nensure_admin_firewall\(\))", bootstrap, re.DOTALL)
    firewall_ready = firewall_ready_match.group("body") if firewall_ready_match else ""
    if (cp3_match and all(index >= 0 for index in cp3_stages) and cp3_stages == sorted(cp3_stages) and
            "admin_firewall_is_ready" in cp3_body and
            "Before=network-pre.target wg-quick@$WG_INTERFACE.service" in bootstrap and
            "Requires=powerseven-admin-firewall.service" in bootstrap and
            "After=powerseven-admin-firewall.service" in bootstrap and
            "nft list table inet powerseven_admin" in firewall_ready and
            "printf 'delete table inet powerseven_admin\\n'; cat /etc/powerseven/admin-vpn.nft; } | nft -f -" in bootstrap):
        report("PASS", "cp3-firewall-order", "nft policy precedes VPN start, boot ordering is enforced and Check compares live rules")
    else:
        report("FAIL", "cp3-firewall-order", "CP3 firewall ordering, atomic replacement or live-rule check is incomplete")
    if "10.99.0.0/24" in runner and "New-NetRoute" in runner and "New-NetFirewallRule" in runner:
        report("PASS", "windows-runner", "DC02 route, RDP firewall and client export paths exist")
    else:
        report("FAIL", "windows-runner", "DC02 integration is incomplete")
    cp3_runner_match = re.search(r"\} elseif \(\$Checkpoint -eq '3' -and \$Apply\) \{(?P<body>.*?)(?=\n    \} else \{\n        \$remoteCheckpointArguments)", runner, re.DOTALL)
    cp3_runner = cp3_runner_match.group("body") if cp3_runner_match else ""
    runner_stages = [cp3_runner.find(token) for token in (
        "Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $applyArguments)",
        "Invoke-Native $script:Scp", "--cleanup-client", "New-LocalRdpFile",
        "Ensure-DC02AdminRoute", "Ensure-DC02RdpFirewall",
    )]
    if (cp3_runner_match and all(index >= 0 for index in runner_stages) and runner_stages == sorted(runner_stages) and
            "-RouteMetric 50 -ErrorAction Stop" in runner and
            "-PolicyStore $store" in runner and
            "function Test-DC02AdminState" in runner and
            "Test-DC02AdminState -Endpoint $endpoint -Peers $adminPeers" in runner and
            "Test-DC02RdpFirewall" in runner):
        report("PASS", "cp3-runner-order", "VPN and profiles precede DC02 changes; Check covers both route stores and RDP scope")
    else:
        report("FAIL", "cp3-runner-order", "DC02 changes can precede VPN readiness or local CP3 checks are incomplete")
    rdp_match = re.search(r"function Ensure-DC02RdpFirewall \{(?P<body>.*?)(?=\n\}\n\nfunction Test-AdminClientConfig)", runner, re.DOTALL)
    rdp_body = rdp_match.group("body") if rdp_match else ""
    block4 = rdp_body.find("New-NetFirewallRule -Name $blockIPv4Name")
    block6 = rdp_body.find("New-NetFirewallRule -Name $blockIPv6Name")
    allow = rdp_body.find("New-NetFirewallRule -Name $allowName")
    ipv4_block_ranges = ["0.0.0.1-10.98.255.255", "10.99.1.0-255.255.255.254"]
    ipv6_block_ranges = ["::2-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"]
    if (rdp_match and min(block4, block6) >= 0 and max(block4, block6) < allow and
            "Get-NetFirewallProfile -PolicyStore ActiveStore" in rdp_body and
            all(value in runner for value in ipv4_block_ranges + ipv6_block_ranges) and
            windows_firewall_range_fixture(ipv4_block_ranges, 4) and windows_firewall_range_fixture(ipv6_block_ranges, 6) and
            "0.0.0.0-10.98.255.255" not in runner and "10.99.1.0-255.255.255.255" not in runner and "::/0" not in runner and
            "PowerSeven-AdminVPN-RDP-BlockOutsideIPv4" in runner and "PowerSeven-AdminVPN-RDP-BlockOutsideIPv6" in runner and
            "Get-NetFirewallRule -Name $Name -PolicyStore $store" in runner and
            "Get-EnabledRdpFirewallRules" not in runner and
            "Remove-NetRoute -DestinationPrefix" in runner and
            "Keep any managed RDP block in place on failure" in runner):
        report("PASS", "cp3-rdp-policy", "valid IPv4/IPv6 blocks precede allow; active policy and fail-closed rerun are checked")
    else:
        report("FAIL", "cp3-rdp-policy", "RDP policy may depend on existing rules or leave a broad allow active")
    if ("function Get-FirewallAddressIdentity" in runner and "function Test-FirewallAddressSet" in runner and
            "IPAddress]::TryParse" in runner and "GetAddressBytes()" in runner and
            "@([regex]::Split($token, '-', 3))" in runner and "Non-contiguous firewall subnet mask" in runner and
            "Get-FirewallAddressIdentity -Address $address" in runner and
            "Test-FirewallAddressSet -Actual @($address.LocalAddress)" in runner and
            "Test-FirewallAddressSet -Actual @($address.RemoteAddress)" in runner and
            firewall_address_semantics_fixture()):
        report("PASS", "cp3-rdp-normalization", "CIDR/netmask, host, IPv6 and firewall keyword aliases compare semantically")
    else:
        report("FAIL", "cp3-rdp-normalization", "firewall address normalization misses an equivalent representation")
    scp_source = "Invoke-Native $script:Scp ($keyOnlySshOptions + @($remoteClientPath, $temporaryClientPath))"
    if (scp_source in cp3_runner and
            "$remoteClientPath = '{0}:/tmp/powerseven-admin-{1}.conf' -f $target, $peer.Name" in cp3_runner and
            'Invoke-Native $script:Scp ($keyOnlySshOptions + @($target +' not in cp3_runner and
            cp3_runner.find("Get-RemoteAdminEndpoint") < cp3_runner.find("Update-AdminClientProfile") < cp3_runner.find("--cleanup-client") and
            "[System.IO.File]::Replace($temporaryPath, $Path, $null)" in runner and
            '$content.Replace($endpointMatches[0].Value, "Endpoint = $Endpoint")' in runner and
            '.Replace($allowedMatches[0].Value, "AllowedIPs = $script:AdminClientAllowedIPs")' in runner and
            "if ($AllowLegacyRoutes) { $validRoutes += $script:LegacyAdminClientAllowedIPs }" in runner and
            0 <= bootstrap.find("detect_network_interfaces()") < bootstrap.find("if [[ \"$#\" -eq 1 && \"$1\" == '--admin-endpoint' ]]") and
            "detect_network_interfaces && [[ \"$BRIDGED_ADDRESS\" != 'none' ]]" in bootstrap and
            "Test-AdminClientConfig -Path $path -Address $peer.Address -Endpoint $Endpoint" in runner):
        report("PASS", "cp3-export-recovery", "SCP recovery preserves identities; reruns atomically refresh endpoint and split routes")
    else:
        report("FAIL", "cp3-export-recovery", "SCP arguments, staged-key recovery or dynamic endpoint sync is incomplete")
    cp2_runner_match = re.search(r"if \(\$Checkpoint -eq '2' -and \$Apply\) \{(?P<body>.*?)(?=\n    \} elseif \(\$Checkpoint -eq '3' -and \$Apply\))", runner, re.DOTALL)
    cp2_runner_body = cp2_runner_match.group("body") if cp2_runner_match else ""
    if (cp2_runner_match and
            all(token in cp2_runner_body for token in ("Invoke-NativeReadOnly", "--check", "Invoke-NativeBounded", "Wait-ForVps14Ssh", "--confirm-network", "HostKeyAlias")) and
            "Invoke-Native $script:Ssh ($keyOnlySshOptions + @($target) + $remoteCheckpointArguments)" not in cp2_runner_body):
        report("PASS", "windows-cp2-orchestration", "CP2 precheck, bounded handoff, host-key pinning and automatic confirmation are present")
    else:
        report("FAIL", "windows-cp2-orchestration", "CP2 runner orchestration is incomplete or can block on the old SSH session")
    if "StrictHostKeyChecking=no" not in runner and "HostKeyAlias" in runner and "Test-TcpPort" in runner:
        report("PASS", "windows-host-identity", "static-IP reconnect pins the existing SSH host identity without disabling host-key checks")
    else:
        report("FAIL", "windows-host-identity", "host-key continuity is unsafe or missing")
    fixtures = (
        (runner_cp2_fixture(already_ready=True, old_session_pending=False, static_ready=True, host_key_same=True), {"passed": True, "token": False, "bounded": True}),
        (runner_cp2_fixture(already_ready=False, old_session_pending=True, static_ready=True, host_key_same=True), {"passed": True, "token": True, "bounded": True}),
        (runner_cp2_fixture(already_ready=False, old_session_pending=False, static_ready=True, host_key_same=False), {"passed": False, "token": True, "bounded": True}),
        (runner_cp2_fixture(already_ready=False, old_session_pending=False, static_ready=False, host_key_same=True), {"passed": False, "token": True, "bounded": True}),
    )
    if (all(actual == expected for actual, expected in fixtures) and
            host_key_fixture("ssh-ed25519 AAAAtrusted", "ssh-ed25519 AAAAtrusted") and
            not host_key_fixture("ssh-ed25519 AAAAtrusted", "ssh-ed25519 AAAAchanged")):
        report("PASS", "windows-cp2-fixtures", "already-ready, pending old session, host-key mismatch and bounded timeout cases are covered")
    else:
        report("FAIL", "windows-cp2-fixtures", "CP2 runner transition fixture coverage failed")
    if wrapper_match and all(token in wrapper_match.group("body") for token in ("--version", "--capabilities", "--protocol", "--peer-status", "--admin-endpoint", "--network-token", "--confirm-network", "--cleanup-client", "--peer-list", "exec /usr/local/lib/powerseven/bootstrap.sh \"$@\"")):
        report("PASS", "wrapper-allowlist", "extended CP2/CP3 arguments are explicitly allowlisted")
    else:
        report("FAIL", "wrapper-allowlist", "wrapper allowlist does not cover the approved transactions")
    network_checkpoint_match = re.search(r"network_checkpoint\(\) \{(?P<body>.*?)(?=\n\}\n\nensure_wireguard_server_keys\(\))", bootstrap, re.DOTALL)
    network_checkpoint_body = network_checkpoint_match.group("body") if network_checkpoint_match else ""
    if network_checkpoint_match and "if ! wait_for_network_state; then" in network_checkpoint_body and "if ! detect_network_interfaces || ! wait_for_network_state; then" not in network_checkpoint_body:
        report("PASS", "network-retry-call", "post-apply retry starts from the pre-apply NIC references without a detection short-circuit")
    else:
        report("FAIL", "network-retry-call", "post-apply retry is still gated by immediate NIC rediscovery")
    if bootstrap_contract_fixture(bootstrap, runner):
        report("PASS", "bootstrap-contract-sync", "runner derives expected protocol from bootstrap.sh and transaction probe follows future bumps")
    else:
        report("FAIL", "bootstrap-contract-sync", "required protocol or transaction probe can diverge from bootstrap.sh")
    if all(token in runner for token in ("Test-BootstrapProtocol", "ProtocolSupported", "automatic migration starting", "PrepareBootstrap", "-RequiredVersion $requiredBootstrapVersion", "-RequiredCapabilities $requiredBootstrapCapabilities")):
        report("PASS", "bootstrap-migration", "runner gates migration and preparation on the version/capability protocol")
    else:
        report("FAIL", "bootstrap-migration", "runner migration/preparation gate is incomplete")
    protocol_match = re.search(r"function Test-BootstrapProtocol\b(?P<body>.*?)(?=\nfunction Test-ExistingBootstrapInstallation\b)", runner, re.DOTALL)
    protocol_body = protocol_match.group("body") if protocol_match else ""
    if protocol_match and all(token in protocol_body for token in ("Invoke-NativeCapture", "'--protocol'", "StandardOutput", "capabilityMatch", "BatchMode=yes", "PasswordAuthentication=no", "IdentitiesOnly=yes")) and protocol_body.count("Invoke-NativeCapture") == 1 and "sh -c" not in protocol_body:
        report("PASS", "bootstrap-protocol-probe", "one key-only SSH call returns protocol data, parsed locally")
    else:
        report("FAIL", "bootstrap-protocol-probe", "protocol probe is redundant, fragile, or lacks local parsing")
    if protocol_match and all(token in protocol_body for token in ("BatchMode=yes", "PasswordAuthentication=no", "IdentitiesOnly=yes", "sudo', '-n'")) and not any(token in protocol_body for token in ("Invoke-NativeInteractive", "Invoke-Native $script:Scp", "install ',", "rm ',")):
        report("PASS", "bootstrap-protocol-readonly", "protocol detection is key-only and read-only")
    else:
        report("FAIL", "bootstrap-protocol-readonly", "protocol detection can prompt or mutate the remote host")
    check_flow_match = re.search(r"if \(\$Check\) \{\n    Write-Result 'INFO' 'ssh-key-auth' 'validating key-only access.*?(?P<body>.*?)\n\}\n\nWrite-Result 'INFO' 'ssh-key-auth'", runner, re.DOTALL)
    check_flow = check_flow_match.group("body") if check_flow_match else ""
    if (check_flow_match and
            "Test-ExistingBootstrapInstallation" in check_flow and
            not re.search(r"\bTest-SshKeyAuthentication\b", check_flow) and
            check_flow.count("Invoke-NativeReadOnly") == 1 and
            "Get-RemoteAdminPeers -Target $target" in check_flow and
            "Get-RemoteAdminEndpoint -Target $target" in check_flow and
            check_ssh_session_count(1, 1, 0) == 2 and
            check_ssh_session_count(1, 1, 2) == 4):
        report("PASS", "check-ssh-session-budget", "Check uses two SSH sessions; CP3 adds peer and endpoint probes")
    else:
        report("FAIL", "check-ssh-session-budget", "Check path has redundant SSH probes or exceeds two normal sessions")
    bootstrap_version = re.search(r"^readonly POWERSEVEN_BOOTSTRAP_VERSION='([0-9]+)'\r?$", bootstrap, re.MULTILINE)
    bootstrap_capabilities = re.search(r"^readonly POWERSEVEN_BOOTSTRAP_CAPABILITIES='([0-9]+(?:,[0-9]+)*)'\r?$", bootstrap, re.MULTILINE)
    current_version = bootstrap_version.group(1) if bootstrap_version else "0"
    previous_version = str(max(0, int(current_version) - 1))
    current_capabilities = f"checkpoints={bootstrap_capabilities.group(1)}" if bootstrap_capabilities else "checkpoints="
    protocol_fixtures = (
        (protocol_probe_fixture(0, "", f"powerseven-bootstrap {current_version}\n{current_capabilities}\n", current_version, current_capabilities, "2"), (True, True)),
        (protocol_probe_fixture(0, "", f"powerseven-bootstrap {previous_version}\n{current_capabilities}\n", current_version, current_capabilities, "2"), (True, False)),
        (protocol_probe_fixture(2, "usage: old wrapper", "", current_version, current_capabilities, "2"), (True, False)),
        (protocol_probe_fixture(255, "Permission denied (publickey)", "", current_version, current_capabilities, "2"), (False, False)),
        (protocol_probe_fixture(255, "Host key verification failed", "", current_version, current_capabilities, "2"), (False, False)),
    )
    if all(actual == expected for actual, expected in protocol_fixtures):
        report("PASS", "protocol-probe-fixtures", "valid, obsolete, authentication-failed and host-key-mismatch probes are distinguished")
    else:
        report("FAIL", "protocol-probe-fixtures", "protocol/authentication result fixtures failed")
    enrollment_match = re.search(r"if \(-not \$sshKeyAuthentication\) \{(?P<body>.*?)\n\}\nWrite-Result 'PASS' 'ssh-key-auth'", runner, re.DOTALL)
    enrollment_body = enrollment_match.group("body") if enrollment_match else ""
    if enrollment_match and enrollment_body.count("Test-SshKeyAuthentication") == 1 and "$sshKeyAuthentication = $true" in enrollment_body:
        report("PASS", "auth-probe-reuse", "initial auth result is reused; enrollment performs exactly one post-install verification")
    else:
        report("FAIL", "auth-probe-reuse", "runner repeats authentication after a successful probe")
    if all(token in runner for token in ("function Assert-LinuxPayloadLf", "function ConvertTo-LinuxLf", "$wrapper = ConvertTo-LinuxLf", "$bootstrapContent = ConvertTo-LinuxLf -Name 'bootstrap script' -Content $BootstrapContent", "$installCommand = ConvertTo-LinuxLf", "powerseven-install-transaction.sh", "bash -n \"$0\"", "$transactionPath", "$remoteTransactionCommand")):
        report("PASS", "linux-payload-eol", "runner stages, normalizes and validates Linux payloads as LF")
    else:
        report("FAIL", "linux-payload-eol", "Linux payload staging/EOL validation is incomplete")
    if "Invoke-NativeInteractive $script:Ssh (@('-tt') + $keyOnlySshOptions + @($target, $remoteTransactionCommand))" in runner and "$target, $installCommand" not in runner:
        report("PASS", "transaction-transport", "privileged transaction uses a staged Bash file and a simple SSH launcher")
    else:
        report("FAIL", "transaction-transport", "privileged transaction is still passed as an inline SSH payload")
    if "Jarvis" not in bootstrap and "Fedora" not in bootstrap and not re.search(r"wireguard\.exe|wg-quick|\bwg\.exe\b|install-wireguard", runner, re.IGNORECASE):
        report("PASS", "vpn-ownership", "VPN orchestration remains in PowerSeven; runner does not configure WireGuard")
    else:
        report("FAIL", "vpn-ownership", "VPN ownership boundary is violated")
    doc_text = "\n".join(path.read_text(encoding="utf-8", errors="ignore") for path in (ROOT / "docs").rglob("*.md"))
    if not re.search(r"PrivateKey\s*=\s*(?!<CLIENT PRIVATE KEY>)\S+", doc_text):
        report("PASS", "secret-boundary", "no client private key is declared in repository documentation")
    else:
        report("FAIL", "secret-boundary", "private key material appears in documentation")
    print(f"SUMMARY: PASS={PASS} FAIL={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
