#!/usr/bin/env python3
"""Allowlisted dependency-aware controller for PowerSeven applications."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


STATE_DIR = Path("/run/powerseven")
LOCK_PATH = Path("/run/lock/powerseven-controller.lock")
POSTGRESQL = "postgresql"
POSTGRESQL_UNIT = "postgresql@18-main.service"
REDIS = "nextcloud-redis"
FORGEJO = "soc-forgejo-forgejo-1"
NEXTCLOUD = "soc-cloud-app-1"
NEXTCLOUD_CRON = "soc-cloud-cron-1"
NEXTCLOUD_REDIS = "soc-cloud-redis-1"

FORGEJO_COMPOSE = (
    "docker", "compose", "--project-directory", "/opt/soc-forgejo",
    "-f", "/opt/soc-forgejo/compose.yaml",
)
NEXTCLOUD_COMPOSE = (
    "docker", "compose", "--project-directory", "/opt/soc-cloud",
    "-f", "/opt/soc-cloud/compose.yaml",
)

# Runtime files are a cache. Every transition discovers active applications
# from Docker/systemd and recalculates this union.
APPLICATION_DEPENDENCIES = {
    "forgejo": {"docker.service", POSTGRESQL},
    "nextcloud": {"docker.service", POSTGRESQL, REDIS},
    "stirling": {"docker.service"},
    "scribble": {"docker.service"},
    "pterodactyl": {
        "docker.service", "mariadb.service", "redis-server.service",
        "php8.3-fpm.service", "wings.service",
    },
    "wazuh": {
        "wazuh-indexer.service", "wazuh-manager.service",
        "wazuh-dashboard.service", "filebeat.service",
    },
}
CORE_SERVICES = {
    "wg-quick@wg0.service", "ssh.socket", "docker.service", "nginx.service",
    "azienda-portal.service", "powerseven-dashboard-health.service",
    "powerseven-core.target", "powerseven-core-adguard.service", "cockpit.socket",
}
DEPENDENCY_UNITS = {"docker.service": "docker.service", POSTGRESQL: POSTGRESQL_UNIT}
MANAGED_SERVICES = set(DEPENDENCY_UNITS.values())
STOPPABLE_DEPENDENCIES = {POSTGRESQL, REDIS}
APP_CONTAINERS = {
    "forgejo": (FORGEJO,),
    "nextcloud": (NEXTCLOUD,),
    "stirling": ("soc-stirling-stirling-1",),
    "scribble": (
        "8fe0a128-6fb0-44ad-b6da-a7a83a1c44b5",
        "548ab28c-0e73-4706-a894-959a2d1b76a1",
    ),
}
ALLOWED_CONTAINERS = {
    *sum(APP_CONTAINERS.values(), ()), NEXTCLOUD_CRON, NEXTCLOUD_REDIS,
}


class ControllerError(RuntimeError):
    pass


def command(argv: list[str], *, timeout: int = 30, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ControllerError(f"{' '.join(argv)}: {detail}")
    return result


def unit_for(reference: str) -> str:
    unit = DEPENDENCY_UNITS.get(reference, reference)
    if unit not in MANAGED_SERVICES | CORE_SERVICES:
        raise ControllerError(f"unit is not allowlisted: {reference}")
    return unit


def service_active(reference: str) -> bool:
    return command(["systemctl", "is-active", "--quiet", unit_for(reference)], check=False).returncode == 0


def container_status(name: str) -> str:
    if name not in ALLOWED_CONTAINERS:
        raise ControllerError(f"container is not allowlisted: {name}")
    result = command(["docker", "inspect", "-f", "{{.State.Status}}", name], check=False)
    return result.stdout.strip() if result.returncode == 0 else "missing"


def container_running(name: str) -> bool:
    return container_status(name) == "running"


def active_applications() -> set[str]:
    return {
        app for app, containers in APP_CONTAINERS.items()
        if any(container_running(container) for container in containers)
    }


def desired_dependencies(active: set[str]) -> set[str]:
    unknown = active - APPLICATION_DEPENDENCIES.keys()
    if unknown:
        raise ControllerError(f"unknown active applications: {', '.join(sorted(unknown))}")
    required: set[str] = set()
    for app in active:
        required |= APPLICATION_DEPENDENCIES[app]
    return required


def actual_dependencies() -> set[str]:
    actual: set[str] = set()
    if service_active("docker.service"):
        actual.add("docker.service")
    if service_active(POSTGRESQL):
        actual.add(POSTGRESQL)
    if container_running(NEXTCLOUD_REDIS):
        actual.add(REDIS)
    return actual


def write_atomic(name: str, value: str) -> None:
    STATE_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=STATE_DIR, delete=False) as stream:
        stream.write(value)
        temp_name = stream.name
    os.chmod(temp_name, 0o644)
    os.replace(temp_name, STATE_DIR / name)


def pg_ready() -> bool:
    return command(["pg_isready", "-h", "10.10.10.14", "-p", "5432"], check=False).returncode == 0


def redis_ready() -> bool:
    return container_running(NEXTCLOUD_REDIS) and command(
        ["docker", "exec", NEXTCLOUD_REDIS, "redis-cli", "ping"], timeout=10, check=False
    ).returncode == 0


def nextcloud_http_ready() -> bool:
    return command(
        ["curl", "--fail", "--silent", "--show-error", "--max-time", "5", "http://127.0.0.1:8083/status.php"],
        check=False,
    ).returncode == 0


def forgejo_health() -> bool:
    if not container_running(FORGEJO):
        return False
    health = command(
        ["docker", "inspect", "-f", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", FORGEJO],
        check=False,
    ).stdout.strip()
    return health == "healthy" and command(
        ["curl", "--fail", "--silent", "--show-error", "--max-time", "5", "http://127.0.0.1:3001/"],
        check=False,
    ).returncode == 0


def health_snapshot(active: set[str]) -> dict[str, str]:
    health = {
        "docker.service": "PASS" if service_active("docker.service") else "FAIL",
        POSTGRESQL: "PASS" if pg_ready() else "OFF",
        REDIS: "PASS" if redis_ready() else "OFF",
    }
    if "forgejo" in active:
        health["forgejo"] = "PASS" if forgejo_health() else "FAIL"
    if "nextcloud" in active:
        health["nextcloud"] = "PASS" if nextcloud_http_ready() else "FAIL"
        health["nextcloud-cron"] = "PASS" if container_running(NEXTCLOUD_CRON) else "FAIL"
    return health


def external_postgres_consumer() -> tuple[bool, str]:
    if not service_active(POSTGRESQL):
        return False, ""
    query = (
        "select count(*) from pg_stat_activity "
        "where pid <> pg_backend_pid() and datname is not null "
        "and datname not in ('postgres','template0','template1')"
    )
    result = command(["runuser", "-u", "postgres", "--", "psql", "-Atqc", query], check=False)
    if result.returncode or not result.stdout.strip().isdigit():
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: PostgreSQL activity could not be verified"
    if int(result.stdout.strip()) > 0:
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: non-system PostgreSQL client remains"
    return False, ""


def ensure_service(reference: str) -> None:
    unit = unit_for(reference)
    if reference not in DEPENDENCY_UNITS:
        raise ControllerError(f"service start is not allowlisted: {reference}")
    if not service_active(reference):
        command(["systemctl", "start", unit], timeout=60)


def wait_until(check, description: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(2)
    raise ControllerError(f"timeout waiting for {description}")


def ensure_dependency(dependency: str) -> None:
    if dependency == "docker.service":
        ensure_service(dependency)
    elif dependency == POSTGRESQL:
        ensure_service(dependency)
        wait_until(pg_ready, POSTGRESQL_UNIT, 30)
    elif dependency == REDIS:
        if not container_running(NEXTCLOUD_REDIS):
            command([*NEXTCLOUD_COMPOSE, "up", "-d", "--no-deps", "redis"], timeout=120)
        wait_until(redis_ready, NEXTCLOUD_REDIS, 30)
    else:
        raise ControllerError(f"dependency start is not allowlisted: {dependency}")


def stop_unused_dependencies(required: set[str]) -> str:
    blocked = ""
    if REDIS not in required and container_running(NEXTCLOUD_REDIS):
        command([*NEXTCLOUD_COMPOSE, "stop", "redis"], timeout=90)
    if POSTGRESQL not in required and service_active(POSTGRESQL):
        external, reason = external_postgres_consumer()
        if external:
            blocked = reason
        else:
            command(["systemctl", "stop", POSTGRESQL_UNIT], timeout=60)
    return blocked


def reconcile(active: set[str]) -> str:
    required = desired_dependencies(active)
    for dependency in sorted(required):
        ensure_dependency(dependency)
    return stop_unused_dependencies(required)


def save_state(*, health: str = "PASS", failure: str = "") -> None:
    active = active_applications()
    required = desired_dependencies(active)
    actual = actual_dependencies()
    profile = "NONE" if not active else "+".join(sorted(active)).upper()
    write_atomic("active-applications", "\n".join(sorted(active)) + ("\n" if active else ""))
    write_atomic("active-profile", profile + "\n")
    write_atomic("required-dependencies", "\n".join(sorted(required)) + ("\n" if required else ""))
    write_atomic("actual-dependencies", "\n".join(sorted(actual)) + ("\n" if actual else ""))
    write_atomic("services", json.dumps({unit: service_active(unit) for unit in sorted(MANAGED_SERVICES)}, sort_keys=True) + "\n")
    memory = command(["free", "--bytes"], check=False).stdout
    memory_line = next((line.strip() for line in memory.splitlines() if line.startswith("Mem:")), "unknown")
    write_atomic("ram", memory_line + "\n")
    write_atomic("health", health + "\n")
    write_atomic("last-transition", datetime.now(timezone.utc).isoformat() + "\n")
    write_atomic("last-failure", failure + ("\n" if failure else ""))


def wait_for_forgejo() -> None:
    wait_until(forgejo_health, "Forgejo health", 120)


def wait_for_nextcloud() -> None:
    wait_until(lambda: container_running(NEXTCLOUD) and nextcloud_http_ready(), "Nextcloud health", 120)


def start_forgejo() -> None:
    reconcile(active_applications() | {"forgejo"})
    if not container_running(FORGEJO):
        command([*FORGEJO_COMPOSE, "up", "-d", "--no-deps", "forgejo"], timeout=120)
    wait_for_forgejo()
    save_state()


def stop_forgejo() -> None:
    if container_running(FORGEJO):
        command([*FORGEJO_COMPOSE, "stop", "forgejo"], timeout=90)
    blocked = reconcile(active_applications())
    save_state(health=blocked or "PASS", failure=blocked)


def start_nextcloud() -> None:
    reconcile(active_applications() | {"nextcloud"})
    if not container_running(NEXTCLOUD):
        command([*NEXTCLOUD_COMPOSE, "up", "-d", "--no-deps", "app"], timeout=180)
    wait_for_nextcloud()
    if not container_running(NEXTCLOUD_CRON):
        command([*NEXTCLOUD_COMPOSE, "up", "-d", "--no-deps", "cron"], timeout=120)
    wait_until(lambda: container_running(NEXTCLOUD_CRON), "Nextcloud cron", 30)
    save_state()


def stop_nextcloud() -> None:
    if container_running(NEXTCLOUD_CRON):
        command([*NEXTCLOUD_COMPOSE, "stop", "cron"], timeout=90)
    if container_running(NEXTCLOUD):
        command([*NEXTCLOUD_COMPOSE, "stop", "app"], timeout=90)
    blocked = reconcile(active_applications())
    save_state(health=blocked or "PASS", failure=blocked)


def discover_actual_state() -> dict[str, object]:
    active = active_applications()
    required = desired_dependencies(active)
    actual = actual_dependencies()
    return {"active_applications": sorted(active), "desired_dependencies": sorted(required),
            "actual_dependencies": sorted(actual), "health": health_snapshot(active)}


def status() -> int:
    state = discover_actual_state()
    print(json.dumps(state, sort_keys=True))
    health = state["health"]
    return 0 if all(value in {"PASS", "OFF"} for value in health.values()) else 1


def reconcile_command() -> int:
    active = active_applications()
    blocked = reconcile(active)
    save_state(health=blocked or "PASS", failure=blocked)
    print(json.dumps(discover_actual_state(), sort_keys=True))
    return 0


def self_check() -> int:
    assert desired_dependencies(set()) == set()
    assert desired_dependencies({"forgejo"}) == {"docker.service", POSTGRESQL}
    assert desired_dependencies({"nextcloud"}) == {"docker.service", POSTGRESQL, REDIS}
    assert desired_dependencies({"forgejo", "nextcloud"}) == {"docker.service", POSTGRESQL, REDIS}
    assert unit_for(POSTGRESQL) == POSTGRESQL_UNIT
    assert POSTGRESQL_UNIT in MANAGED_SERVICES
    assert "docker.service" not in STOPPABLE_DEPENDENCIES
    assert POSTGRESQL not in CORE_SERVICES
    print("PASS: concrete PostgreSQL unit, desired-state union, shared Redis, and protected CORE")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["self-check"]:
        return self_check()
    if argv in (["status"], ["plan"]):
        return status()
    if argv == ["reconcile"]:
        action = reconcile_command
    elif argv in (["forgejo", "start"], ["forgejo", "stop"], ["nextcloud", "start"], ["nextcloud", "stop"]):
        action = {
            ("forgejo", "start"): start_forgejo,
            ("forgejo", "stop"): stop_forgejo,
            ("nextcloud", "start"): start_nextcloud,
            ("nextcloud", "stop"): stop_nextcloud,
        }[(argv[0], argv[1])]
    else:
        print("usage: powerseven-controller {forgejo|nextcloud} {start|stop} | status | reconcile | self-check", file=sys.stderr)
        return 2

    LOCK_PATH.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with LOCK_PATH.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            return action() or 0
        except (ControllerError, subprocess.TimeoutExpired) as error:
            message = str(error)
            try:
                write_atomic("last-failure", message + "\n")
                write_atomic("health", "FAILED\n")
            except Exception:
                pass
            print(f"FAILED: {message}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
