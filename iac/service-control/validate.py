#!/usr/bin/env python3
"""Validate the dependency-aware service-control declarations without a host."""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None


ROOT = Path(__file__).resolve().parent
failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"FAIL: {message}")


def load(path: Path):
    if yaml is None:
        fail("PyYAML is unavailable")
        return {}
    try:
        with path.open(encoding="utf-8") as stream:
            return yaml.safe_load(stream) or {}
    except Exception as error:
        fail(f"cannot parse {path.name}: {error}")
        return {}


def visit(node: str, graph: dict[str, set[str]], visiting: set[str], visited: set[str]) -> None:
    if node in visiting:
        fail(f"dependency cycle at {node}")
        return
    if node in visited:
        return
    visiting.add(node)
    for requirement in graph.get(node, set()):
        if requirement in graph:
            visit(requirement, graph, visiting, visited)
    visiting.remove(node)
    visited.add(node)


def main() -> int:
    profiles = load(ROOT / "profiles.yml")
    dependencies = load(ROOT / "dependency-map.yml")
    healthchecks = load(ROOT / "healthchecks.yml")
    optimization = load(ROOT / "optimization.yml")
    compose = load(ROOT / "../docker/compose.yml")

    protected = set(profiles.get("boot", {}).get("protected_units", []))
    expected_core = {
        "wg-quick@wg0.service", "ssh.socket", "docker.service", "nginx.service",
        "azienda-portal.service", "powerseven-dashboard-health.service",
        "powerseven-core-adguard.service", "cockpit.socket", "powerseven-core.target",
    }
    if protected != expected_core:
        fail("protected CORE set is not exact")
    if "postgresql.service" in protected:
        fail("PostgreSQL must not be CORE")
    if profiles.get("architecture", {}).get("postgresql_core") is not False:
        fail("architecture must declare PostgreSQL non-CORE")
    if profiles.get("architecture", {}).get("dashboard", {}).get("postgres_dependency") != "none":
        fail("dashboard must have no PostgreSQL dependency")

    app_names = {"FORGEJO", "NEXTCLOUD", "STIRLING", "SCRIBBLE", "PTERODACTYL_PANEL", "PTERODACTYL_WINGS", "WAZUH"}
    apps = dependencies.get("applications", {})
    if set(apps) != app_names or set(profiles.get("applications", {})) != app_names:
        fail("application catalog is incomplete")
    graph = {name: {ref for ref in spec.get("requires", []) if ref in app_names} for name, spec in apps.items()}
    for node in graph:
        visit(node, graph, set(), set())
    if apps.get("FORGEJO", {}).get("requires") != ["docker.service", "postgresql"]:
        fail("Forgejo dependency declaration is incorrect")
    if "postgresql" not in apps.get("NEXTCLOUD", {}).get("requires", []):
        fail("Nextcloud must declare PostgreSQL")

    declared_core = set(dependencies.get("core_services", []))
    if declared_core != expected_core:
        fail("dependency map CORE is not exact")
    shared = dependencies.get("shared_dependencies", {})
    if shared.get("postgresql", {}).get("systemd_unit") != "postgresql@18-main.service":
        fail("PostgreSQL dependency must target postgresql@18-main.service")
    if shared.get("postgresql", {}).get("stop_policy") != "stop_only_when_not_required":
        fail("PostgreSQL stop policy must be desired-state based")
    if shared.get("docker.service", {}).get("stop_policy") != "never":
        fail("Docker must be protected")

    core_checks = healthchecks.get("profiles", {}).get("core", [])
    if any(check.get("unit") == "postgresql.service" for check in core_checks):
        fail("CORE healthchecks must not require PostgreSQL")
    if not healthchecks.get("profiles", {}).get("forgejo"):
        fail("Forgejo healthchecks are missing")
    nextcloud_checks = healthchecks.get("profiles", {}).get("nextcloud", [])
    if not {check.get("unit") for check in nextcloud_checks if check.get("unit")} >= {"postgresql@18-main.service"}:
        fail("Nextcloud healthchecks must use the concrete PostgreSQL cluster")
    if not any(check.get("container") == "soc-cloud-redis-1" for check in nextcloud_checks):
        fail("Nextcloud Redis healthcheck is missing")
    stirling_checks = healthchecks.get("profiles", {}).get("stirling", [])
    if apps.get("STIRLING", {}).get("requires") != ["docker.service"]:
        fail("Stirling must require Docker only")
    if not any(check.get("container") == "soc-stirling-stirling-1" for check in stirling_checks):
        fail("Stirling container healthcheck is missing")
    if not any(check.get("url") == "http://127.0.0.1:8084/api/v1/info/status" for check in stirling_checks):
        fail("Stirling HTTP healthcheck is missing")
    scribble_checks = healthchecks.get("profiles", {}).get("scribble", [])
    if apps.get("SCRIBBLE", {}).get("requires") != ["docker.service", "wings.service"]:
        fail("Scribble must require Docker and Wings")
    if not any(check.get("id") == "wings-control-plane" for check in scribble_checks):
        fail("Scribble Wings control-plane healthcheck is missing")
    if {check.get("container") for check in scribble_checks if check.get("container")} != {
        "8fe0a128-6fb0-44ad-b6da-a7a83a1c44b5", "548ab28c-0e73-4706-a894-959a2d1b76a1"
    }:
        fail("Scribble container healthchecks are incomplete")
    if {check.get("url") for check in scribble_checks if check.get("url")} != {
        "http://10.10.10.14:8081/", "http://10.10.10.14:8082/"
    }:
        fail("Scribble HTTP healthchecks are incomplete")
    panel_checks = healthchecks.get("profiles", {}).get("pterodactyl-panel", [])
    if apps.get("PTERODACTYL_PANEL", {}).get("requires") != [
        "mariadb.service", "redis-server.service", "php8.3-fpm.service", "pteroq.service"
    ]:
        fail("Pterodactyl panel dependency declaration is incorrect")
    if {check.get("unit") for check in panel_checks if check.get("unit")} < {
        "mariadb.service", "redis-server.service", "php8.3-fpm.service", "pteroq.service",
        "powerseven-pterodactyl-schedule.timer",
    }:
        fail("Pterodactyl panel healthchecks are incomplete")
    if not any(check.get("url") == "https://panel.lab.test/" for check in panel_checks):
        fail("Pterodactyl panel HTTP healthcheck is missing")
    wings_checks = healthchecks.get("profiles", {}).get("pterodactyl-wings", [])
    if apps.get("PTERODACTYL_WINGS", {}).get("requires") != ["docker.service"]:
        fail("Pterodactyl Wings dependency declaration is incorrect")
    if {check.get("unit") for check in wings_checks if check.get("unit")} < {"docker.service", "wings.service"}:
        fail("Pterodactyl Wings systemd healthchecks are incomplete")
    if not any(check.get("network") == "pterodactyl_nw" for check in wings_checks):
        fail("Pterodactyl Wings network healthcheck is missing")
    if not any(check.get("id") == "panel-reachability-for-fresh-start" for check in wings_checks):
        fail("Pterodactyl Wings fresh-start panel reachability check is missing")
    wazuh_requires = [
        "wazuh-indexer.service", "wazuh-manager.service",
        "filebeat.service", "wazuh-dashboard.service",
    ]
    wazuh_checks = healthchecks.get("profiles", {}).get("wazuh", [])
    if apps.get("WAZUH", {}).get("requires") != wazuh_requires:
        fail("Wazuh dependency declaration or order is incorrect")
    if profiles.get("applications", {}).get("WAZUH", {}).get("requires") != wazuh_requires:
        fail("Wazuh profile dependency declaration is incorrect")
    if profiles.get("applications", {}).get("WAZUH", {}).get("native_units_enabled_at_boot") is not False:
        fail("Wazuh native units must be disabled at boot")
    if {check.get("unit") for check in wazuh_checks if check.get("unit")} < set(wazuh_requires):
        fail("Wazuh systemd healthchecks are incomplete")
    if not {check.get("id") for check in wazuh_checks} >= {
        "indexer_https_local", "manager_api_local", "filebeat_service", "dashboard_https_local",
    }:
        fail("Wazuh local endpoint healthchecks are incomplete")

    components = optimization.get("components", {})
    if "forgejo" not in components or "postgresql" not in components or "pterodactyl-panel" not in components:
        fail("optimization matrix must include Forgejo, PostgreSQL, and Pterodactyl panel")
    if "restart" in str(compose) and any(spec.get("restart") not in (None, "no") for spec in compose.get("services", {}).values()):
        fail("local Compose target has a controller-bypassing restart policy")

    systemd = ROOT / "systemd"
    required = {
        "powerseven-core.target", "powerseven-dashboard-health.service",
        "powerseven-app-forgejo.service", "powerseven-app-nextcloud.service",
        "powerseven-app-stirling.service",
        "powerseven-app-scribble.service",
        "powerseven-app-pterodactyl-panel.service",
        "powerseven-app-pterodactyl-wings.service",
        "powerseven-app-wazuh.service",
        "powerseven-pterodactyl-schedule.service",
        "powerseven-pterodactyl-schedule.timer",
        "powerseven-wg-final-dns.service",
    }
    names = {path.name for path in systemd.iterdir()}
    if not required <= names:
        fail("required systemd templates are missing")
    if "powerseven-profile-forgejo.service" in names:
        fail("legacy Forgejo profile unit must not remain")
    if "powerseven-profile-nextcloud.service" in names:
        fail("legacy Nextcloud profile unit must not remain")
    if "powerseven-profile-stirling.service" in names:
        fail("legacy Stirling profile unit must not remain")
    if "powerseven-profile-scribble.service" in names:
        fail("legacy Scribble profile unit must not remain")
    if "powerseven-profile-pterodactyl.service" in names:
        fail("legacy Pterodactyl profile unit must not remain")
    if "powerseven-profile-wazuh.service" in names:
        fail("legacy Wazuh profile unit must not remain")
    dns_unit = systemd / "powerseven-wg-final-dns.service"
    dns_text = dns_unit.read_text(encoding="utf-8")
    for required_dns_line in (
        "resolvectl dns wg-final 10.10.10.13",
        "resolvectl domain wg-final ~lab.test",
        "resolvectl revert wg-final",
        "sys-subsystem-net-devices-wg\\x2dfinal.device",
    ):
        if required_dns_line not in dns_text:
            fail(f"wg-final split-DNS unit is missing: {required_dns_line}")
    if any(forbidden in dns_text for forbidden in ("systemd/network", ".network", "networkctl")):
        fail("wg-final split-DNS unit must not delegate the interface to systemd-networkd")
    core_unit = (systemd / "powerseven-core.target").read_text(encoding="utf-8")
    dashboard_unit = (systemd / "powerseven-dashboard-health.service").read_text(encoding="utf-8")
    if "postgresql.service" in core_unit or "postgresql.service" in dashboard_unit:
        fail("CORE systemd templates must not require PostgreSQL")

    controller = (ROOT / "powerseven-controller.py").read_text(encoding="utf-8")
    for forbidden in ("docker compose down", "systemctl stop docker.service", "systemctl stop nginx.service", "systemctl stop ssh.socket"):
        if forbidden in controller:
            fail(f"controller contains forbidden action: {forbidden}")
    if 'POSTGRESQL_UNIT = "postgresql@18-main.service"' not in controller:
        fail("controller does not pin the concrete PostgreSQL cluster")
    if "external_postgres_consumer" not in controller or "BLOCKED_BY_EXTERNAL_CONSUMER" not in controller:
        fail("controller lacks external PostgreSQL consumer protection")
    if "nextcloud-redis" not in controller or "docker compose down" in controller:
        fail("controller lacks shared Redis or uses compose down")
    if "fcntl.flock" not in controller or "desired_dependencies" not in controller or "discover_actual_state" not in controller:
        fail("controller lacks lock, desired-state union, or actual-state discovery")
    if "stirling_health" not in controller or "start_stirling" not in controller or "stop_stirling" not in controller:
        fail("controller lacks Stirling lifecycle and health handling")
    if "scribble_health" not in controller or "start_scribble" not in controller or "stop_scribble" not in controller:
        fail("controller lacks Scribble lifecycle and health handling")
    if "pterodactyl_panel_health" not in controller or "start_pterodactyl_panel" not in controller or "stop_pterodactyl_panel" not in controller:
        fail("controller lacks Pterodactyl panel lifecycle and health handling")
    if "active_server_processes" not in controller or "BLOCKED_BY_ACTIVE_SERVERS" not in controller:
        fail("controller lacks Wings active-server protection")
    if "start_pterodactyl_wings" not in controller or "stop_pterodactyl_wings" not in controller:
        fail("controller lacks Pterodactyl Wings lifecycle handling")
    if "BLOCKED_BY_PANEL_UNAVAILABLE" not in controller or "panel_runtime_reachable" not in controller:
        fail("controller lacks Wings panel reachability precondition")
    if "mariadb.service" not in controller or "redis-server.service" not in controller or "php8.3-fpm.service" not in controller:
        fail("controller lacks Pterodactyl shared dependencies")
    if not all(token in controller for token in (
        "WAZUH_INDEXER", "WAZUH_MANAGER", "WAZUH_DASHBOARD", "FILEBEAT",
        "def start_wazuh", "def stop_wazuh", "def wazuh_health",
    )):
        fail("controller lacks bounded Wazuh lifecycle and health handling")
    if not (systemd / "wings.service.d" / "powerseven.conf").exists():
        fail("Wings controller-owned restart policy override is missing")
    if "postgresql.service" in controller:
        fail("controller contains ambiguous PostgreSQL aggregator reference")
    if '"scribble": {"docker.service", WINGS}' not in controller:
        fail("controller does not model Wings as a Scribble runtime dependency")
    if "def scribble_power" not in controller or "/api/servers/{server}/power" not in controller:
        fail("controller lacks the local Wings Scribble power API")
    scribble_start = controller.split("def start_scribble", 1)[1].split("def stop_scribble", 1)[0]
    scribble_stop = controller.split("def stop_scribble", 1)[1].split("def start_pterodactyl_scheduler", 1)[0]
    if '"docker", "start"' in scribble_start or '"docker", "stop"' in scribble_stop:
        fail("Scribble lifecycle must not directly start or stop Docker containers")
    wazuh_unit = (systemd / "powerseven-app-wazuh.service").read_text(encoding="utf-8")
    if "TimeoutStartSec=8min" not in wazuh_unit or "TimeoutStopSec=5min" not in wazuh_unit:
        fail("Wazuh app unit must have bounded lifecycle timeouts")
    if "Restart=" in wazuh_unit or "WantedBy=multi-user.target" not in wazuh_unit:
        fail("Wazuh app unit must be controller-owned and non-restarting")

    if failures:
        print(f"SUMMARY: FAIL={len(failures)}")
        return 1
    print("PASS: YAML, concrete PostgreSQL cluster, dependency graph, external-consumer safety, controller, healthchecks, and templates")
    print("SUMMARY: FAIL=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
