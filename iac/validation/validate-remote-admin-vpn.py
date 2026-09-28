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
    if str(admin_net) == "10.99.0.0/24" and admin_plan["server"] == "10.99.0.1/24" and admin_plan["first_client"] == "10.99.0.2/32":
        report("PASS", "admin-vpn-addresses", "dedicated 10.99.0.0/24 plan is declared")
    else:
        report("FAIL", "admin-vpn-addresses", "admin VPN address plan is inconsistent")
    if "10.10.10.0/24" not in admin["allowed_ips"] or admin["nat"]["default"] is not False:
        report("FAIL", "routing-policy", "admin VPN must route lab overlay without making NAT the default")
    else:
        report("PASS", "routing-policy", "no masquerade default; lab overlay is future/allowed routing")
    route = admin["return_routes"]["dc02"]
    if route == {"destination": "10.99.0.0/24", "via": "192.168.214.14"}:
        report("PASS", "dc02-route", "persistent return route target is declared")
    else:
        report("FAIL", "dc02-route", "DC02 return route is incomplete")

    if all(token in bootstrap for token in ("network_checkpoint", "vpn_checkpoint", "--confirm-network", "wg-admin", "10.99.0.1/24", "10.99.0.2/32")):
        report("PASS", "linux-bootstrap", "CP2/CP3 and rollback/client paths exist")
    else:
        report("FAIL", "linux-bootstrap", "CP2/CP3 implementation markers are incomplete")
    if "10.99.0.0/24" in runner and "New-NetRoute" in runner and "Set-NetFirewallAddressFilter" in runner:
        report("PASS", "windows-runner", "DC02 route, RDP firewall and client export paths exist")
    else:
        report("FAIL", "windows-runner", "DC02 integration is incomplete")
    if wrapper_match and all(token in wrapper_match.group("body") for token in ("--version", "--capabilities", "--network-token", "--confirm-network", "--cleanup-client", "exec /usr/local/lib/powerseven/bootstrap.sh \"$@\"")):
        report("PASS", "wrapper-allowlist", "extended CP2/CP3 arguments are explicitly allowlisted")
    else:
        report("FAIL", "wrapper-allowlist", "wrapper allowlist does not cover the approved transactions")
    if all(token in bootstrap for token in ("POWERSEVEN_BOOTSTRAP_VERSION", "POWERSEVEN_BOOTSTRAP_CAPABILITIES", "--version", "--capabilities")):
        report("PASS", "bootstrap-protocol", "version and checkpoint capabilities are explicitly exposed")
    else:
        report("FAIL", "bootstrap-protocol", "bootstrap version/capabilities protocol is incomplete")
    if all(token in runner for token in ("$requiredBootstrapVersion = '2'", "$requiredBootstrapCapabilities = 'checkpoints=1,2,3'", "Test-BootstrapProtocol", "ProtocolSupported", "automatic migration starting", "PrepareBootstrap")):
        report("PASS", "bootstrap-migration", "runner gates migration and preparation on the version/capability protocol")
    else:
        report("FAIL", "bootstrap-migration", "runner migration/preparation gate is incomplete")
    if all(token in runner for token in ("function Assert-LinuxPayloadLf", "function ConvertTo-LinuxLf", "$wrapper = ConvertTo-LinuxLf", "$bootstrapContent = ConvertTo-LinuxLf", "$installCommand = ConvertTo-LinuxLf", "powerseven-install-transaction.sh", "bash -n \"$0\"", "$transactionPath", "$remoteTransactionCommand")):
        report("PASS", "linux-payload-eol", "runner stages, normalizes and validates Linux payloads as LF")
    else:
        report("FAIL", "linux-payload-eol", "Linux payload staging/EOL validation is incomplete")
    if "Invoke-NativeInteractive $script:Ssh @('-tt', '-o', 'PasswordAuthentication=no', '-o', 'IdentitiesOnly=yes', '-i', $keyPath, $target, $remoteTransactionCommand)" in runner and "$target, $installCommand" not in runner:
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
