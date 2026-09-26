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

    app_names = {"FORGEJO", "NEXTCLOUD", "STIRLING", "SCRIBBLE", "PTERODACTYL", "WAZUH"}
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

    components = optimization.get("components", {})
    if "forgejo" not in components or "postgresql" not in components:
        fail("optimization matrix must include Forgejo and PostgreSQL")
    if "restart" in str(compose) and any(spec.get("restart") not in (None, "no") for spec in compose.get("services", {}).values()):
        fail("local Compose target has a controller-bypassing restart policy")

    systemd = ROOT / "systemd"
    required = {
        "powerseven-core.target", "powerseven-dashboard-health.service",
        "powerseven-app-forgejo.service", "powerseven-app-nextcloud.service",
        "powerseven-app-stirling.service",
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
    if "postgresql.service" in controller:
        fail("controller contains ambiguous PostgreSQL aggregator reference")

    if failures:
        print(f"SUMMARY: FAIL={len(failures)}")
        return 1
    print("PASS: YAML, concrete PostgreSQL cluster, dependency graph, external-consumer safety, controller, healthchecks, and templates")
    print("SUMMARY: FAIL=0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
