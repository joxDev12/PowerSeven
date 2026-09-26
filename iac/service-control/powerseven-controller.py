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
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


STATE_DIR = Path("/run/powerseven")
LOCK_PATH = Path("/run/lock/powerseven-controller.lock")
POSTGRESQL = "postgresql"
POSTGRESQL_UNIT = "postgresql@18-main.service"
REDIS = "nextcloud-redis"
FORGEJO = "soc-forgejo-forgejo-1"
NEXTCLOUD = "soc-cloud-app-1"
NEXTCLOUD_CRON = "soc-cloud-cron-1"
NEXTCLOUD_REDIS = "soc-cloud-redis-1"
STIRLING = "soc-stirling-stirling-1"
MARIADB = "mariadb.service"
REDIS_SERVER = "redis-server.service"
PHP_FPM = "php8.3-fpm.service"
PTEROQ = "pteroq.service"
WINGS = "wings.service"
WINGS_CONFIG = Path("/etc/pterodactyl/config.yml")
WINGS_API_URL = "http://127.0.0.1:8080"
PTERODACTYL_NETWORK = "pterodactyl_nw"
PTERODACTYL_PANEL_SCHEDULER = "powerseven-pterodactyl-schedule.service"
PTERODACTYL_PANEL_TIMER = "powerseven-pterodactyl-schedule.timer"
PANEL_HEALTH_URL = "https://panel.lab.test/"
WINGS_HEALTH_URL = "http://127.0.0.1:8080/"
SCRIBBLE_CONTAINERS = (
    "8fe0a128-6fb0-44ad-b6da-a7a83a1c44b5",
    "548ab28c-0e73-4706-a894-959a2d1b76a1",
)
SCRIBBLE_PORTS = {
    SCRIBBLE_CONTAINERS[0]: 8081,
    SCRIBBLE_CONTAINERS[1]: 8082,
}

FORGEJO_COMPOSE = (
    "docker", "compose", "--project-directory", "/opt/soc-forgejo",
    "-f", "/opt/soc-forgejo/compose.yaml",
)
NEXTCLOUD_COMPOSE = (
    "docker", "compose", "--project-directory", "/opt/soc-cloud",
    "-f", "/opt/soc-cloud/compose.yaml",
)
STIRLING_COMPOSE = (
    "docker", "compose", "--project-directory", "/opt/soc-stirling",
    "-f", "/opt/soc-stirling/compose.yaml",
)

# Runtime files are a cache. Every transition discovers active applications
# from Docker/systemd and recalculates this union.
APPLICATION_DEPENDENCIES = {
    "forgejo": {"docker.service", POSTGRESQL},
    "nextcloud": {"docker.service", POSTGRESQL, REDIS},
    "stirling": {"docker.service"},
    "scribble": {"docker.service", WINGS},
    "pterodactyl-panel": {MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ},
    "pterodactyl-wings": {"docker.service"},
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
DEPENDENCY_UNITS = {
    "docker.service": "docker.service",
    POSTGRESQL: POSTGRESQL_UNIT,
    MARIADB: MARIADB,
    REDIS_SERVER: REDIS_SERVER,
    PHP_FPM: PHP_FPM,
    PTEROQ: PTEROQ,
    WINGS: WINGS,
}
MANAGED_SERVICES = set(DEPENDENCY_UNITS.values()) | {WINGS, PTERODACTYL_PANEL_TIMER, PTERODACTYL_PANEL_SCHEDULER}
STOPPABLE_DEPENDENCIES = {POSTGRESQL, REDIS, MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ}
DEPENDENCY_START_ORDER = (
    "docker.service", POSTGRESQL, MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ, REDIS, WINGS,
)
APP_CONTAINERS = {
    "forgejo": (FORGEJO,),
    "nextcloud": (NEXTCLOUD,),
    "stirling": (STIRLING,),
    "scribble": SCRIBBLE_CONTAINERS,
}
ALLOWED_CONTAINERS = {
    *sum(APP_CONTAINERS.values(), ()), NEXTCLOUD_CRON, NEXTCLOUD_REDIS,
}


class ControllerError(RuntimeError):
    pass


class ControllerBlocked(ControllerError):
    def __init__(self, message: str, health: str):
        super().__init__(message)
        self.health = health


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
    active = {
        app for app, containers in APP_CONTAINERS.items()
        if any(container_running(container) for container in containers)
    }
    if service_active(PTEROQ) or service_active(PTERODACTYL_PANEL_TIMER):
        active.add("pterodactyl-panel")
    if service_active(WINGS):
        active.add("pterodactyl-wings")
    return active


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
    for dependency in ("docker.service", POSTGRESQL, MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ, REDIS, WINGS):
        if dependency == REDIS:
            present = container_running(NEXTCLOUD_REDIS)
        else:
            present = service_active(dependency)
        if present:
            actual.add(dependency)
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


def mariadb_ready() -> bool:
    return command(["mysqladmin", "--protocol=socket", "ping"], timeout=10, check=False).returncode == 0


def redis_server_ready() -> bool:
    result = command(["redis-cli", "-h", "127.0.0.1", "-p", "6379", "PING"], timeout=10, check=False)
    return result.returncode == 0 and result.stdout.strip() == "PONG"


def nextcloud_http_ready() -> bool:
    return command(
        ["curl", "--fail", "--silent", "--show-error", "--max-time", "5", "http://127.0.0.1:8083/status.php"],
        check=False,
    ).returncode == 0


def stirling_health() -> bool:
    if not container_running(STIRLING):
        return False
    health = command(
        ["docker", "inspect", "-f", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", STIRLING],
        check=False,
    ).stdout.strip()
    return health == "healthy" and command(
        ["curl", "--fail", "--silent", "--show-error", "--max-time", "5",
         "http://127.0.0.1:8084/api/v1/info/status"],
        check=False,
    ).returncode == 0


def scribble_health() -> bool:
    return all(
        container_running(container)
        and command(
            ["curl", "--fail", "--silent", "--show-error", "--max-time", "5",
             f"http://10.10.10.14:{SCRIBBLE_PORTS[container]}/"],
            check=False,
        ).returncode == 0
        for container in SCRIBBLE_CONTAINERS
    )


def pterodactyl_network_exists() -> bool:
    return command(["docker", "network", "inspect", PTERODACTYL_NETWORK], timeout=10, check=False).returncode == 0


def pterodactyl_panel_health() -> bool:
    return (
        mariadb_ready()
        and redis_server_ready()
        and service_active(PHP_FPM)
        and service_active(PTEROQ)
        and service_active(PTERODACTYL_PANEL_TIMER)
        and command(
            ["curl", "--fail", "--silent", "--show-error", "--insecure", "--max-time", "5",
             "--resolve", "panel.lab.test:443:127.0.0.1", PANEL_HEALTH_URL],
            check=False,
        ).returncode == 0
    )


def wings_health() -> bool:
    if not service_active(WINGS) or not service_active("docker.service") or not pterodactyl_network_exists():
        return False
    result = command(
        ["curl", "--silent", "--show-error", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", WINGS_HEALTH_URL],
        check=False,
    )
    return result.returncode == 0 and result.stdout.strip() in {"200", "401", "404"}


def panel_runtime_reachable() -> bool:
    return command(["getent", "hosts", "panel.lab.test"], timeout=5, check=False).returncode == 0 and command(
        ["curl", "--fail", "--silent", "--show-error", "--insecure", "--max-time", "5", PANEL_HEALTH_URL],
        check=False,
    ).returncode == 0


def active_server_processes() -> list[str]:
    result = command(
        ["docker", "ps", "-q", "--filter", "label=Service=Pterodactyl", "--filter", "label=ContainerType=server_process"],
        timeout=10,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]


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
        MARIADB: "PASS" if mariadb_ready() else "OFF",
        REDIS_SERVER: "PASS" if redis_server_ready() else "OFF",
        PHP_FPM: "PASS" if service_active(PHP_FPM) else "OFF",
        PTEROQ: "PASS" if service_active(PTEROQ) else "OFF",
        WINGS: "PASS" if wings_health() else "OFF",
    }
    if "forgejo" in active:
        health["forgejo"] = "PASS" if forgejo_health() else "FAIL"
    if "nextcloud" in active:
        health["nextcloud"] = "PASS" if nextcloud_http_ready() else "FAIL"
        health["nextcloud-cron"] = "PASS" if container_running(NEXTCLOUD_CRON) else "FAIL"
    if "stirling" in active:
        health["stirling"] = "PASS" if stirling_health() else "FAIL"
    if "scribble" in active:
        health["scribble"] = "PASS" if scribble_health() else "FAIL"
    if "pterodactyl-panel" in active:
        health["pterodactyl-panel"] = "PASS" if pterodactyl_panel_health() else "FAIL"
    if "pterodactyl-wings" in active:
        health["pterodactyl-wings"] = "PASS" if wings_health() else "FAIL"
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
    elif dependency == MARIADB:
        ensure_service(dependency)
        wait_until(mariadb_ready, MARIADB, 60)
    elif dependency == REDIS_SERVER:
        ensure_service(dependency)
        wait_until(redis_server_ready, REDIS_SERVER, 30)
    elif dependency in {PHP_FPM, PTEROQ}:
        ensure_service(dependency)
    elif dependency == REDIS:
        if not container_running(NEXTCLOUD_REDIS):
            command([*NEXTCLOUD_COMPOSE, "up", "-d", "--no-deps", "redis"], timeout=120)
        wait_until(redis_ready, NEXTCLOUD_REDIS, 30)
    elif dependency == WINGS:
        ensure_wings_dependency()
    else:
        raise ControllerError(f"dependency start is not allowlisted: {dependency}")


def external_mariadb_consumer() -> tuple[bool, str]:
    query = (
        "select count(*) from information_schema.processlist "
        "where id <> connection_id() and user not in ('system user')"
    )
    result = command(["mysql", "--protocol=socket", "-NBe", query], timeout=10, check=False)
    if result.returncode or not result.stdout.strip().isdigit():
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: MariaDB activity could not be verified"
    if int(result.stdout.strip()) > 0:
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: non-controller MariaDB client remains"
    return False, ""


def external_redis_consumer() -> tuple[bool, str]:
    result = command(["redis-cli", "-h", "127.0.0.1", "-p", "6379", "--raw", "CLIENT", "LIST"], timeout=10, check=False)
    if result.returncode:
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: Redis activity could not be verified"
    clients = [line for line in result.stdout.splitlines() if line.strip()]
    own_clients = sum("cmd=client|list" in line for line in clients)
    if len(clients) - own_clients > 0:
        return True, "BLOCKED_BY_EXTERNAL_CONSUMER: non-controller Redis client remains"
    return False, ""


def stop_unused_dependencies(required: set[str]) -> str:
    blocked: list[str] = []
    if PTEROQ not in required:
        stop_pterodactyl_scheduler()
        if service_active(PTEROQ):
            command(["systemctl", "stop", PTEROQ], timeout=60)
    if PHP_FPM not in required and service_active(PHP_FPM):
        command(["systemctl", "stop", PHP_FPM], timeout=60)
    if REDIS not in required and container_running(NEXTCLOUD_REDIS):
        command([*NEXTCLOUD_COMPOSE, "stop", "redis"], timeout=90)
    if REDIS_SERVER not in required and service_active(REDIS_SERVER):
        external, reason = external_redis_consumer()
        if external:
            blocked.append(reason)
        else:
            command(["systemctl", "stop", REDIS_SERVER], timeout=60)
    if MARIADB not in required and service_active(MARIADB):
        external, reason = external_mariadb_consumer()
        if external:
            blocked.append(reason)
        else:
            command(["systemctl", "stop", MARIADB], timeout=120)
    if POSTGRESQL not in required and service_active(POSTGRESQL):
        external, reason = external_postgres_consumer()
        if external:
            blocked.append(reason)
        else:
            command(["systemctl", "stop", POSTGRESQL_UNIT], timeout=60)
    return "; ".join(blocked)


def reconcile(active: set[str]) -> str:
    required = desired_dependencies(active)
    order = {dependency: index for index, dependency in enumerate(DEPENDENCY_START_ORDER)}
    for dependency in sorted(required, key=lambda item: order.get(item, len(order))):
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


def wait_for_stirling() -> None:
    wait_until(stirling_health, "Stirling health", 180)


def wait_for_scribble() -> None:
    wait_until(scribble_health, "Scribble health", 60)


def wait_for_pterodactyl_panel() -> None:
    wait_until(pterodactyl_panel_health, "Pterodactyl panel health", 120)


def wait_for_wings() -> None:
    wait_until(wings_health, "Wings health", 60)


def wings_node_token() -> str:
    if not WINGS_CONFIG.is_file():
        raise ControllerError(f"Wings configuration is missing: {WINGS_CONFIG}")
    for line in WINGS_CONFIG.read_text(encoding="utf-8").splitlines():
        if line.startswith("token:"):
            token = line.partition(":")[2].strip().strip("'\"")
            if token:
                return token
    raise ControllerError("Wings node token is missing from its root-only configuration")


def scribble_power(action: str, servers: tuple[str, ...]) -> None:
    if action not in {"start", "stop"}:
        raise ControllerError(f"unsupported Scribble power action: {action}")
    if any(server not in SCRIBBLE_CONTAINERS for server in servers):
        raise ControllerError("Scribble power request contains a non-allowlisted server")
    token = wings_node_token()
    for server in servers:
        request = Request(
            f"{WINGS_API_URL}/api/servers/{server}/power",
            data=json.dumps({"action": action}).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urlopen(request, timeout=10) as response:
                if response.status not in {200, 202, 204}:
                    raise ControllerError(f"Wings rejected Scribble {action} for allowlisted server")
        except HTTPError as error:
            raise ControllerError(
                f"Wings rejected Scribble {action} for allowlisted server: HTTP {error.code}"
            ) from error
        except (URLError, TimeoutError) as error:
            raise ControllerError(f"Wings API unavailable for Scribble {action}: {error.reason if isinstance(error, URLError) else error}") from error


def start_temporary_panel_runtime() -> None:
    for dependency in (MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ):
        ensure_dependency(dependency)
    start_pterodactyl_scheduler()
    wait_for_pterodactyl_panel()


def ensure_wings_dependency() -> None:
    if service_active(WINGS):
        return

    temporary_panel = not panel_runtime_reachable()
    if temporary_panel:
        start_temporary_panel_runtime()

    try:
        if not pterodactyl_network_exists():
            raise ControllerError(f"required Docker network is missing: {PTERODACTYL_NETWORK}")
        command(["systemctl", "start", WINGS], timeout=90)
        wait_for_wings()
    finally:
        if temporary_panel:
            stop_pterodactyl_scheduler()


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


def start_stirling() -> None:
    reconcile(active_applications() | {"stirling"})
    if not container_running(STIRLING):
        command([*STIRLING_COMPOSE, "up", "-d", "--no-deps", "stirling"], timeout=120)
    wait_for_stirling()
    save_state()


def stop_stirling() -> None:
    if container_running(STIRLING):
        command([*STIRLING_COMPOSE, "stop", "stirling"], timeout=90)
    blocked = reconcile(active_applications())
    save_state(health=blocked or "PASS", failure=blocked)


def start_scribble() -> None:
    temporary_panel = not panel_runtime_reachable()
    if temporary_panel:
        start_temporary_panel_runtime()
    try:
        reconcile(active_applications() | {"scribble"})
        stopped = tuple(container for container in SCRIBBLE_CONTAINERS if not container_running(container))
        if stopped:
            scribble_power("start", stopped)
        wait_for_scribble()
    finally:
        if temporary_panel:
            stop_pterodactyl_scheduler()
            stop_unused_dependencies({"docker.service", WINGS})
    save_state()


def stop_scribble() -> None:
    running = tuple(container for container in SCRIBBLE_CONTAINERS if container_running(container))
    if running:
        scribble_power("stop", running)
        wait_until(
            lambda: all(not container_running(container) for container in SCRIBBLE_CONTAINERS),
            "Scribble Pterodactyl stop",
            60,
        )
    blocked = reconcile(active_applications())
    save_state(health=blocked or "PASS", failure=blocked)


def start_pterodactyl_scheduler() -> None:
    if not service_active(PTERODACTYL_PANEL_TIMER):
        command(["systemctl", "start", PTERODACTYL_PANEL_TIMER], timeout=30)


def stop_pterodactyl_scheduler() -> None:
    if service_active(PTERODACTYL_PANEL_TIMER):
        command(["systemctl", "stop", PTERODACTYL_PANEL_TIMER], timeout=30)
    if service_active(PTERODACTYL_PANEL_SCHEDULER):
        command(["systemctl", "stop", PTERODACTYL_PANEL_SCHEDULER], timeout=60)


def start_pterodactyl_panel() -> None:
    reconcile(active_applications() | {"pterodactyl-panel"})
    start_pterodactyl_scheduler()
    wait_for_pterodactyl_panel()
    save_state()


def stop_pterodactyl_panel() -> None:
    stop_pterodactyl_scheduler()
    if service_active(PTEROQ):
        command(["systemctl", "stop", PTEROQ], timeout=60)
    blocked = reconcile(active_applications())
    save_state(health=blocked or "PASS", failure=blocked)


def start_pterodactyl_wings() -> None:
    if not panel_runtime_reachable():
        reason = "BLOCKED_BY_PANEL_UNAVAILABLE: panel.lab.test DNS/HTTPS/HTTP reachability is required for a fresh Wings start"
        save_state(health="BLOCKED_BY_PANEL_UNAVAILABLE", failure=reason)
        raise ControllerBlocked(reason, "BLOCKED_BY_PANEL_UNAVAILABLE")
    reconcile(active_applications() | {"pterodactyl-wings"})
    if not pterodactyl_network_exists():
        raise ControllerError(f"required Docker network is missing: {PTERODACTYL_NETWORK}")
    if not service_active(WINGS):
        command(["systemctl", "start", WINGS], timeout=90)
    wait_for_wings()
    save_state()


def stop_pterodactyl_wings() -> None:
    processes = active_server_processes()
    if processes:
        reason = f"BLOCKED_BY_ACTIVE_SERVERS: {len(processes)} server_process container(s) remain active"
        save_state(health="BLOCKED_BY_ACTIVE_SERVERS", failure=reason)
        raise ControllerBlocked(reason, "BLOCKED_BY_ACTIVE_SERVERS")
    if service_active(WINGS):
        command(["systemctl", "stop", WINGS], timeout=90)
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
    assert desired_dependencies({"stirling"}) == {"docker.service"}
    assert desired_dependencies({"scribble"}) == {"docker.service", WINGS}
    assert desired_dependencies({"pterodactyl-panel"}) == {MARIADB, REDIS_SERVER, PHP_FPM, PTEROQ}
    assert desired_dependencies({"pterodactyl-wings"}) == {"docker.service"}
    assert len(SCRIBBLE_CONTAINERS) == 2
    assert unit_for(POSTGRESQL) == POSTGRESQL_UNIT
    assert POSTGRESQL_UNIT in MANAGED_SERVICES
    assert "docker.service" not in STOPPABLE_DEPENDENCIES
    assert MARIADB in STOPPABLE_DEPENDENCIES
    assert REDIS_SERVER in STOPPABLE_DEPENDENCIES
    assert PHP_FPM in STOPPABLE_DEPENDENCIES
    assert PTEROQ in STOPPABLE_DEPENDENCIES
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
    elif argv in (["forgejo", "start"], ["forgejo", "stop"], ["nextcloud", "start"], ["nextcloud", "stop"], ["stirling", "start"], ["stirling", "stop"], ["scribble", "start"], ["scribble", "stop"], ["pterodactyl-panel", "start"], ["pterodactyl-panel", "stop"], ["pterodactyl-wings", "start"], ["pterodactyl-wings", "stop"]):
        action = {
            ("forgejo", "start"): start_forgejo,
            ("forgejo", "stop"): stop_forgejo,
            ("nextcloud", "start"): start_nextcloud,
            ("nextcloud", "stop"): stop_nextcloud,
            ("stirling", "start"): start_stirling,
            ("stirling", "stop"): stop_stirling,
            ("scribble", "start"): start_scribble,
            ("scribble", "stop"): stop_scribble,
            ("pterodactyl-panel", "start"): start_pterodactyl_panel,
            ("pterodactyl-panel", "stop"): stop_pterodactyl_panel,
            ("pterodactyl-wings", "start"): start_pterodactyl_wings,
            ("pterodactyl-wings", "stop"): stop_pterodactyl_wings,
        }[(argv[0], argv[1])]
    else:
        print("usage: powerseven-controller {forgejo|nextcloud|stirling|scribble|pterodactyl-panel|pterodactyl-wings} {start|stop} | status | reconcile | self-check", file=sys.stderr)
        return 2

    LOCK_PATH.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    with LOCK_PATH.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            return action() or 0
        except ControllerBlocked as error:
            message = str(error)
            try:
                write_atomic("last-failure", message + "\n")
                write_atomic("health", f"{error.health}\n")
            except Exception:
                pass
            print(f"{error.health}: {message}", file=sys.stderr)
            return 2
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
