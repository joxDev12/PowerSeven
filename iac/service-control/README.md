# PowerSeven service profiles

This is a target-local declaration, not an installer. It does not create VMs,
install Cockpit, contact Azure, or change VPS14.

Normal boot is:

```text
powerseven-core.target
├── powerseven-stop-all-optional.service
└── CORE: WireGuard, SSH, Nginx, dashboard, PostgreSQL (temporary), AdGuard,
    Docker (current AdGuard architecture), and Cockpit socket
```

The PowerSeven dashboard is the primary laboratory GUI and reads only the
status contract under `/run/powerseven`. Cockpit is the technical GUI.
Cockpit's standard Services page starts/stops the concrete optional profile
units. A root-owned controller maps each unit to a fixed Compose project or
systemd allowlist; it accepts no arbitrary unit, shell command, path, or
profile name.
`Conflicts=` makes profiles mutually exclusive. Profile stops leave shared
dependencies available for a fast switch; `ALL-OFF-OPTIONAL` stops those
dependencies explicitly.

Files:

- `profiles.yml`: profile matrix, ports, measured/estimated RAM and boot policy.
- `dependency-map.yml`: protected CORE, conflicts and shared-service policy.
- `healthchecks.yml`: one healthcheck set for every profile.
- `optimization.yml`: measured component costs and reversible optimizations.
- `systemd/`: units to render/install only during a future local provisioning phase.
- `polkit/`: least-privilege rule to review and test before installation.
- `validate.py`: static validator; it never connects to a host.

Run the validator from the repository root:

```sh
python3 iac/service-control/validate.py
```

The local Compose target must use `restart: "no"`. Docker is CORE in the
current architecture only because AdGuard is a CORE container. A future native
AdGuard option may make Docker on-demand if no other CORE consumer remains;
that migration is not implemented.

`azienda-portal.service` and its PostgreSQL `azienda_lab` dependency are CORE
today. An AD/LDAP-primary dashboard is a future optimization, not an existing
dependency change. `PORTAL` remains in the profile catalog as a non-selectable
CORE component for inventory compatibility; it is not an optional profile.

The controller writes a small read-only status contract under `/run/powerseven`:
`active-profile`, `services`, `health`, `ram`, `last-transition`, and
`last-failure`. A failed transition records `FAILED`, leaves CORE untouched,
and exits once; there is no retry loop.

The current Azure host uses `wg-quick@wg0.service`. The future local interface
name remains a provisioning decision; render the profile units only after the
real local WireGuard unit is verified.
