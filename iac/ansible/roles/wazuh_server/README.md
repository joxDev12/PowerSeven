# wazuh_server

Scope: host services for fresh Manager, Indexer and Dashboard with empty
indexes. Inputs: version matrix, TLS refs and overlay endpoint. Requires:
`common_linux`, `wireguard_linux`; Docker is not a prerequisite.

## Indexer JVM source of truth

The role defaults are the single provisioning source for the validated Wazuh
Indexer memory profile:

- `wazuh_indexer_heap_xms: "512m"`
- `wazuh_indexer_heap_xmx: "512m"`
- `wazuh_indexer_max_direct_memory: "256m"`

`tasks/main.yml` applies these values idempotently to the packaged files
`/etc/wazuh-indexer/jvm.options` and `/etc/default/wazuh-indexer` with explicit
task-level privilege escalation. It leaves
G1GC, `AlwaysPreTouch`, Manager, Filebeat and Dashboard configuration alone.
The role assumes the Wazuh packages and their TLS configuration are provided
by the surrounding provisioning stages; it does not duplicate package or
certificate installation.

Wazuh remains on-demand: native units and
`powerseven-app-wazuh.service` are disabled at boot, and the controller starts
Indexer → Manager → Filebeat → Dashboard and stops them in reverse order.
