# Validation

`preflight` è un controllo read-only locale, senza provisioning e senza
connessioni alle VM. Usa Python standard library e PyYAML se disponibile.

Controlla YAML/JSON, riferimenti al grafo, IP/CIDR, secret inline, decisioni
aperte, cicli, DNS, porte, risorse VM e separazione Azure/local.

Pipeline futura:

```text
preflight -> VM definitions -> OS bootstrap -> Ansible syntax/check
          -> Compose config -> acceptance plan
```
