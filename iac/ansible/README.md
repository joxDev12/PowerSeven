# Configuration management

Questa è la superficie Ansible futura. I ruoli sono contratti/documentazione;
non contengono ancora task di provisioning.

Workflow previsto:

```text
bootstrap OS -> inventory underlay -> Ansible check -> Ansible apply
```

Usare sempre `--check --diff` prima di `--apply`. I secret arrivano da
environment/secret store, mai da YAML versionato.
