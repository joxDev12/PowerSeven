# Validation

`preflight` è un controllo read-only locale, senza provisioning e senza
connessioni alle VM. Usa Python standard library e PyYAML se disponibile.

Controlla YAML/JSON, riferimenti al grafo, IP/CIDR, secret inline, decisioni
aperte, cicli, DNS, porte, risorse VM e separazione Azure/local. Verifica
inoltre pin/versione CP4, wrapper/payload allowlist, firewall `DOCKER-USER`,
read-only Check, gate sui servizi con input mancanti e `docker compose config`
con soli placeholder.

Pipeline futura:

```text
preflight -> VM definitions -> OS bootstrap -> Ansible syntax/check
          -> Compose config -> acceptance plan
```
