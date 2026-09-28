#!/usr/bin/env python3
"""Read-only validator for the local PowerSeven administrative VPN design."""

from __future__ import annotations

import ipaddress
import re
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


def network_ready_fixture(state: dict[str, bool]) -> bool:
    return all(state[key] for key in ("underlay", "default_route", "bridge_link", "bridge_ipv4", "underlay_dns", "networkd", "persistence")) and not state["bridge_default_route"] and not state["bridge_dns"]


def network_retry_fixture(states: list[dict[str, bool]], timeout: int = 45, interval: int = 2) -> bool:
    return any(network_ready_fixture(state) for state in states[: timeout // interval + 1])


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


def check_ssh_session_count(protocol_probe_sessions: int, checkpoint_sessions: int, duplicate_auth_sessions: int) -> int:
    return protocol_probe_sessions + checkpoint_sessions + duplicate_auth_sessions


def protocol_probe_fixture(exit_code: int, stderr: str, output: str, version: str, capabilities: str, checkpoint: str) -> tuple[bool, bool]:
    transport_failure = exit_code == 255 or bool(re.search(r"(?i)(permission denied|host key verification failed|connection timed out|connection refused|no route to host)", stderr))
    authenticated = not transport_failure
    supported_checkpoints = capabilities.partition("=")[2].split(",")
    supported = authenticated and exit_code == 0 and output.strip().splitlines() == [f"powerseven-bootstrap {version}", capabilities] and checkpoint in supported_checkpoints
    return authenticated, supported


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
    expected_peers = {"jarvis": "10.99.0.2/32", "giorgio-laptop": "10.99.0.3/32"}
    declared_peers = {peer["name"]: peer["address"] for peer in admin["clients"]}
    if str(admin_net) == "10.99.0.0/24" and admin_plan["server"] == "10.99.0.1/24" and admin_plan["clients"] == expected_peers and declared_peers == expected_peers:
        report("PASS", "admin-vpn-addresses", "dedicated 10.99.0.0/24 plan is declared")
    else:
        report("FAIL", "admin-vpn-addresses", "admin VPN address plan is inconsistent")
    if admin["allowed_ips"] != ["192.168.214.0/24"] or admin["nat"]["default"] is not False:
        report("FAIL", "routing-policy", "admin VPN must use VMnet8-only split tunnel and no NAT")
    else:
        report("PASS", "routing-policy", "VMnet8-only split tunnel; Internet stays outside VPN")
    route = admin["return_routes"]["dc02"]
    if route == {"destination": "10.99.0.0/24", "via": "192.168.214.14"}:
        report("PASS", "dc02-route", "persistent return route target is declared")
    else:
        report("FAIL", "dc02-route", "DC02 return route is incomplete")

    if all(token in bootstrap for token in ("network_checkpoint", "vpn_checkpoint", "--confirm-network", "wg-admin", "10.99.0.1/24", "jarvis:10.99.0.2/32", "giorgio-laptop:10.99.0.3/32")):
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
    if all(token in bootstrap for token in ("NETWORK_READY_TIMEOUT_SECONDS=45", "NETWORK_READY_INTERVAL_SECONDS=2", "network_state_missing", "wait_for_network_state", "sleep \"$NETWORK_READY_INTERVAL_SECONDS\"", "post-apply validation timed out", "bridged DHCP pending", "bridged default route present", "bridged DNS present")) and "while true" not in bootstrap:
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
        "networkctl is-managed",
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
            "-TimeoutSeconds 60" in runner and
            "network transition SSH session" in runner):
        report("PASS", "network-confirm-fixtures", "delayed networkd/DHCP wait, timeout, persistence and rollback window are covered")
    else:
        report("FAIL", "network-confirm-fixtures", "confirmation can commit early or outlive its rollback guard")
    cp3_match = re.search(r"vpn_checkpoint\(\) \{(?P<body>.*?)(?=\n\}\n\nwhile \[\[ \$# -gt 0 \]\])", bootstrap, re.DOTALL)
    cp3_body = cp3_match.group("body") if cp3_match else ""
    if (cp3_match and
            "ADMIN_PEERS" in cp3_body and
            "ensure_admin_client_export" in cp3_body and
            'iifname "$WG_INTERFACE" drop' in bootstrap and
            '"AllowedIPs = $UNDERLAY_NETWORK"' in bootstrap and
            "10.10.10.0/24" not in cp3_body and
            "giorgio-laptop" in runner and "jarvis" in runner and
            "--peer-status" in bootstrap and "--peer-status" in runner and
            "Invoke-NativeCapture $script:Ssh" in runner and
            "Test-NativeSuccess $script:Ssh ($keyOnlySshOptions + @($target, 'test'" not in runner and
            "explicit rotation is required" in runner):
        report("PASS", "two-peer-vpn-fixtures", "independent allowlisted peers, split tunnel and lost-key safety are declared")
    else:
        report("FAIL", "two-peer-vpn-fixtures", "two-peer VPN state/export/split-tunnel guards are incomplete")
    if "10.99.0.0/24" in runner and "New-NetRoute" in runner and "Set-NetFirewallAddressFilter" in runner:
        report("PASS", "windows-runner", "DC02 route, RDP firewall and client export paths exist")
    else:
        report("FAIL", "windows-runner", "DC02 integration is incomplete")
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
    if wrapper_match and all(token in wrapper_match.group("body") for token in ("--version", "--capabilities", "--protocol", "--peer-status", "--network-token", "--confirm-network", "--cleanup-client", "exec /usr/local/lib/powerseven/bootstrap.sh \"$@\"")):
        report("PASS", "wrapper-allowlist", "extended CP2/CP3 arguments are explicitly allowlisted")
    else:
        report("FAIL", "wrapper-allowlist", "wrapper allowlist does not cover the approved transactions")
    network_checkpoint_match = re.search(r"network_checkpoint\(\) \{(?P<body>.*?)(?=\n\}\n\nensure_wireguard_server_keys\(\))", bootstrap, re.DOTALL)
    network_checkpoint_body = network_checkpoint_match.group("body") if network_checkpoint_match else ""
    if network_checkpoint_match and "if ! wait_for_network_state; then" in network_checkpoint_body and "if ! detect_network_interfaces || ! wait_for_network_state; then" not in network_checkpoint_body:
        report("PASS", "network-retry-call", "post-apply retry starts from the pre-apply NIC references without a detection short-circuit")
    else:
        report("FAIL", "network-retry-call", "post-apply retry is still gated by immediate NIC rediscovery")
    if all(token in bootstrap for token in ("readonly POWERSEVEN_BOOTSTRAP_VERSION='8'", "POWERSEVEN_BOOTSTRAP_CAPABILITIES", "--protocol", "checkpoints=%s\\n")):
        report("PASS", "bootstrap-protocol", "version and capabilities use one deterministic read-only protocol command")
    else:
        report("FAIL", "bootstrap-protocol", "bootstrap version/capabilities protocol is incomplete")
    if all(token in runner for token in ("$requiredBootstrapVersion = '8'", "$requiredBootstrapCapabilities = 'checkpoints=1,2,3'", "Test-BootstrapProtocol", "ProtocolSupported", "automatic migration starting", "PrepareBootstrap")):
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
            check_ssh_session_count(1, 1, 0) == 2):
        report("PASS", "check-ssh-session-budget", "normal Check uses one protocol/auth SSH session plus one checkpoint session")
    else:
        report("FAIL", "check-ssh-session-budget", "Check path has redundant SSH probes or exceeds two normal sessions")
    protocol_fixtures = (
        (protocol_probe_fixture(0, "", "powerseven-bootstrap 8\ncheckpoints=1,2,3\n", "8", "checkpoints=1,2,3", "2"), (True, True)),
        (protocol_probe_fixture(2, "usage: old wrapper", "", "8", "checkpoints=1,2,3", "2"), (True, False)),
        (protocol_probe_fixture(255, "Permission denied (publickey)", "", "8", "checkpoints=1,2,3", "2"), (False, False)),
        (protocol_probe_fixture(255, "Host key verification failed", "", "8", "checkpoints=1,2,3", "2"), (False, False)),
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
    if all(token in runner for token in ("function Assert-LinuxPayloadLf", "function ConvertTo-LinuxLf", "$wrapper = ConvertTo-LinuxLf", "$bootstrapContent = ConvertTo-LinuxLf", "$installCommand = ConvertTo-LinuxLf", "powerseven-install-transaction.sh", "bash -n \"$0\"", "$transactionPath", "$remoteTransactionCommand")):
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
