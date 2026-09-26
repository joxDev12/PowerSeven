# PowerSeven service profiles

This is a target-local declaration, not an installer. It does not create VMs,
install Cockpit, contact Azure, or change VPS14.

Normal boot is:

```text
powerseven-core.target
├── powerseven-stop-all-optional.service
└── CORE: WireGuard, SSH, Nginx, AD-only dashboard, AdGuard,
    Docker (current AdGuard architecture), and Cockpit socket
```

The PowerSeven dashboard is the primary laboratory GUI and reads only the
status contract under `/run/powerseven`. Cockpit is the technical GUI.
Cockpit's standard Services page starts/stops the concrete application units.
The root-owned `powerseven-controller.py` maps each application and dependency
to a fixed allowlist; it accepts no arbitrary unit, shell command, path, or
Compose project. Each transition detects active applications and recalculates
the required dependency union. PostgreSQL is stopped only when no active
consumer remains; Docker is CORE and never stopped by an app transition.

Files:

- `profiles.yml`: profile matrix, ports, measured/estimated RAM and boot policy.
- `dependency-map.yml`: protected CORE, application graph and shared-service policy.
- `healthchecks.yml`: one healthcheck set for every profile.
- `optimization.yml`: measured component costs and reversible optimizations.
- `systemd/`: units to render/install only during a future local provisioning phase.
- `polkit/`: least-privilege rule to review and test before installation.
- `validate.py`: static validator; it never connects to a host.

Run the validator from the repository root:

```sh
python3 iac/service-control/validate.py
```

The local Compose target must use `restart: "no"`. Docker is CORE because
AdGuard is a CORE container. PostgreSQL is shared on demand by Forgejo and
Nextcloud, not part of CORE. The PostgreSQL dependency explicitly maps to
`postgresql@18-main.service`; `postgresql.service` is only the aggregator.

`azienda-portal.service` is a CORE component and authenticates directly with
Active Directory. Its former PostgreSQL data remains installed for inspection
and is not a dashboard runtime dependency.

The controller writes a small read-only status contract under `/run/powerseven`:
`active-profile`, `active-applications`, `required-dependencies`,
`actual-dependencies`, `services`, `health`, `ram`, `last-transition`, and
`last-failure`. A failed transition records `FAILED`, leaves CORE untouched,
and exits once; an unknown PostgreSQL client produces
`BLOCKED_BY_EXTERNAL_CONSUMER` and keeps `postgresql@18-main.service` online.

The current Azure host uses `wg-quick@wg0.service`. The future local interface
name remains a provisioning decision; render the profile units only after the
real local WireGuard unit is verified.
