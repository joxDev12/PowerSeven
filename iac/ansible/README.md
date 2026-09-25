# Configuration management

Questa è la superficie Ansible futura. I ruoli sono contratti/documentazione;
non contengono ancora task di provisioning.

Workflow previsto:

```text
bootstrap OS -> inventory underlay -> Ansible check -> Ansible apply
```

Usare sempre `--check --diff` prima di `--apply`. I secret arrivano da
environment/secret store, mai da YAML versionato.

`dependency-map.yml` distingue dipendenze tra ruoli sullo stesso host da
`cross_host_requires`: Nextcloud/Forgejo richiedono AD/LDAP disponibile su
DC02, ma non il ruolo SSSD di VPS12. WireGuard è separato in
`wireguard_linux` e `wireguard_windows`. Pterodactyl segue MariaDB → Panel →
Wings/pteroq; Wazuh Manager/Indexer/Dashboard e azienda-portal sono servizi
host, non dipendono da Docker.
