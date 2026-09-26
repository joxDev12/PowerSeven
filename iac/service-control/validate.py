#!/usr/bin/env python3
"""Validate PowerSeven service-control declarations without touching a host."""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - the repository already requires PyYAML
    yaml = None


ROOT = Path(__file__).resolve().parent
failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"FAIL: {message}")


def load(name: str):
    if yaml is None:
        fail("PyYAML is unavailable")
        return {}
    with (ROOT / name).open(encoding="utf-8") as stream:
        return yaml.safe_load(stream) or {}


def visit(node: str, graph: dict[str, set[str]], visiting: set[str], visited: set[str], path: list[str]) -> None:
    if node in visiting:
        fail("profile dependency cycle: " + " -> ".join(path + [node]))
        return
    if node in visited:
        return
    visiting.add(node)
    for requirement in graph.get(node, set()):
        if requirement in graph:
            visit(requirement, graph, visiting, visited, path + [node])
    visiting.remove(node)
    visited.add(node)


def main() -> int:
    profiles_data = load("profiles.yml")
    dependencies = load("dependency-map.yml")
    healthchecks = load("healthchecks.yml")
    optimization = load("optimization.yml")

    expected_profiles = {
        "CORE", "NEXTCLOUD", "FORGEJO", "STIRLING", "PTERODACTYL",
        "WAZUH", "PORTAL", "SCRIBBLE", "ALL-OFF-OPTIONAL",
    }
    profiles = profiles_data.get("profiles", {})
    if set(profiles) != expected_profiles:
        fail(f"profiles must be exactly {sorted(expected_profiles)}")

    boot = profiles_data.get("boot", {})
    protected = set(boot.get("protected_units", []))
    required_protected = {
        "wg-quick@wg0.service", "ssh.socket", "docker.service", "nginx.service",
        "postgresql.service", "azienda-portal.service",
        "powerseven-dashboard-health.service", "powerseven-core-adguard.service",
        "cockpit.socket", "powerseven-core.target",
    }
    if not required_protected <= protected:
        fail("CORE protection is missing a required protected unit")
    if boot.get("default_profile") != "ALL-OFF-OPTIONAL" or boot.get("core_profile") != "CORE":
        fail("boot default must be ALL-OFF-OPTIONAL with CORE as the core profile")
    if boot.get("docker_restart_policy") != "no":
        fail("Docker restart policy must be no")
    disabled_at_boot = set(boot.get("native_optional_units_disabled_at_boot", []))
    if protected & disabled_at_boot:
        fail("boot disable list contains a protected CORE unit")
    if not {"wazuh-indexer.service", "wazuh-manager.service", "wazuh-dashboard.service"} <= disabled_at_boot:
        fail("boot disable list must include all Wazuh units")

    units: set[str] = set()
    for name, profile in profiles.items():
        unit = profile.get("unit")
        if not unit or unit in units:
            fail(f"{name}: unique systemd unit is required")
        units.add(unit)
        ram = profile.get("ram", {})
        if not isinstance(ram.get("planning_peak_gib"), (int, float)):
            fail(f"{name}: planning_peak_gib is missing")
        if not isinstance(ram.get("minimum_practical_gib"), (int, float)):
            fail(f"{name}: minimum_practical_gib is missing")
        start = profile.get("start_order", [])
        stop = profile.get("stop_order", [])
        if len(start) != len(set(start)) or len(stop) != len(set(stop)):
            fail(f"{name}: start/stop order contains duplicates")
        allowed_steps = set(profile.get("services", [])) | set(profile.get("containers", [])) | {"CORE"}
        allowed_steps |= {step for step in start if str(step).startswith("health-")}
        allowed_steps |= {"stop-optional"}
        for step in start + stop:
            if step not in allowed_steps:
                fail(f"{name}: unknown order step {step}")
        if name not in {"CORE", "ALL-OFF-OPTIONAL"}:
            owned_start = [step for step in start if step != "CORE" and not str(step).startswith("health-")]
            for step in stop:
                if step not in owned_start:
                    fail(f"{name}: stop step {step} is not in its start order")
            positions = [owned_start.index(step) for step in stop if step in owned_start]
            if positions != sorted(positions, reverse=True):
                fail(f"{name}: stop order is not reverse dependency order")
        if name not in {"CORE", "ALL-OFF-OPTIONAL"} and not profile.get("core_component") and profile.get("autostart"):
            fail(f"{name}: optional profile must not autostart")
        if profile.get("heavy") and profile.get("autostart"):
            fail(f"{name}: heavy profile must not autostart")
        if protected & set(stop):
            fail(f"{name}: stop order can stop protected CORE units")

    graph: dict[str, set[str]] = {}
    dependency_profiles = dependencies.get("profiles", {})
    for name in expected_profiles:
        spec = dependency_profiles.get(name, {})
        if not spec:
            fail(f"dependency map missing profile {name}")
        graph[name] = {ref for ref in spec.get("requires", []) if ref in expected_profiles}
        for ref in spec.get("requires", []) + spec.get("conflicts", []):
            if ref not in expected_profiles and not (ref.endswith(".service") or ref in {"id_ldap", "docker.service"}):
                fail(f"{name}: dependency reference does not exist: {ref}")
    for node in graph:
        visit(node, graph, set(), set(), [])

    dep_protected = set(dependencies.get("protected_core", {}).get("units", []))
    if not required_protected <= dep_protected:
        fail("dependency map does not protect all CORE units")
    all_off = dependencies.get("all_off", {})
    if protected & set(all_off.get("stops_systemd", [])):
        fail("ALL-OFF-OPTIONAL attempts to stop a protected CORE unit")
    if not required_protected <= set(all_off.get("leaves_running", [])):
        fail("ALL-OFF-OPTIONAL does not explicitly preserve every protected CORE unit")
    if set(all_off.get("leaves_running", [])) & set(all_off.get("stops_systemd", [])):
        fail("ALL-OFF-OPTIONAL both leaves and stops the same unit")
    if not profiles.get("ALL-OFF-OPTIONAL", {}).get("all_optional_stopped"):
        fail("ALL-OFF-OPTIONAL is not marked as stopping all optional services")
    architecture = profiles_data.get("architecture", {})
    if architecture.get("postgresql_core_reason") != "dashboard_current_dependency":
        fail("PostgreSQL CORE reason must be dashboard_current_dependency")
    if architecture.get("dashboard", {}).get("future_optimization_status") != "not_implemented":
        fail("dashboard AD/LDAP migration must remain future and not implemented")
    if architecture.get("docker", {}).get("current_option") != "A_AdGuard_container_Docker_CORE":
        fail("current Docker decision must document option A")
    if not profiles.get("PORTAL", {}).get("core_component"):
        fail("PORTAL must be marked as the CORE dashboard component")
    if not {"postgresql.service", "azienda-portal.service", "nginx.service"} <= set(profiles.get("CORE", {}).get("services", [])):
        fail("CORE must include PostgreSQL, dashboard, and Nginx")

    health_profiles = healthchecks.get("profiles", {})
    for name in expected_profiles:
        health_name = "all-off" if name == "ALL-OFF-OPTIONAL" else name.lower()
        if not health_profiles.get(health_name):
            fail(f"{name}: missing healthchecks")
        for check in health_profiles.get(health_name, []):
            if not check.get("command"):
                fail(f"{name}: healthcheck {check.get('id')} has no command")
    if set(optimization.get("components", {})) != {
        "wazuh-indexer", "wazuh-dashboard", "wazuh-manager", "postgresql", "mariadb",
        "redis", "docker", "containerd", "adguard-container", "adguard-native-future",
        "nginx", "gunicorn-portal", "pterodactyl-workers",
        "journald", "ubuntu-services",
    }:
        fail("optimization matrix is incomplete")

    compose = load(Path("../docker/compose.yml").as_posix())
    for service, spec in compose.get("services", {}).items():
        if spec.get("restart") != "no":
            fail(f"Compose service {service} bypasses the controller with restart={spec.get('restart')!r}")

    required_units = {
        "powerseven-core.target", "powerseven-core-adguard.service",
        "powerseven-dashboard-health.service",
        "powerseven-stop-all-optional.service",
        *(f"powerseven-profile-{name.lower()}.service" for name in expected_profiles - {"CORE", "ALL-OFF-OPTIONAL", "PORTAL"}),
    }
    template_names = {path.name for path in (ROOT / "systemd").glob("*")}
    if not required_units <= template_names:
        fail("systemd templates missing: " + ", ".join(sorted(required_units - template_names)))
    controller = (ROOT / "systemd" / "powerseven-profile").read_text(encoding="utf-8")
    if re.search(r"systemctl stop[^\n]*(wg|ssh|docker|nginx)", controller):
        fail("controller contains a protected systemd stop")

    if failures:
        print(f"SUMMARY: FAIL={len(failures)}")
        return 1
    print("PASS: profile names, dependencies, CORE protection, healthchecks, RAM estimates, restart policy, and templates")
    print("SUMMARY: FAIL=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
