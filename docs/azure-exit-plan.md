# Azure exit plan PowerSeven

## Criterio di stop

Le VM Azure restano accese finche il laboratorio locale riproduce i tre host,
le dipendenze e i dati critici, e supera il test end-to-end. Questa fase non
esegue migrazione e non modifica le VM.

## Gap Azure verso locale

| Componente | Stato attuale | Dipendenza Azure | Equivalente locale | Automatizzabile | Dati da migrare | Rischio |
|---|---|---|---|---|---|---|
| Azure VNet | `172.16.0.0/24`, underlay privato | Alta | VMware VMnet host-only/custom | Parziale | CIDR e route | Alto: collisione osservata `172.16.0.4` da riconciliare |
| Public IP | ingresso WireGuard UDP `51820` | Alta | IP del laboratorio, NAT solo se necessario | Parziale | endpoint e peer config | Alto: valore/stato Azure non verificato in questa fase |
| Azure NSG | filtro cloud ingress | Alta | firewall host plus rete VMware | Parziale | regole allow/deny | Alto: regole NSG non lette direttamente |
| Dischi VM | root VPS12/VPS14, C: VPS13 | Alta | VMDK locali | Si | filesystem e dati persistenti | Alto: backup/export non ancora testati |
| Hostname | `soc-desktop`, `DC02`, `soc-server` | Bassa | stessi hostname | Si | identita e trust | Medio |
| IP WireGuard | `10.10.10.12-14`, client `.101-.107` | Nessuna | stessa rete overlay | Si | chiavi peer, AllowedIPs | Alto: chiavi sono segreti |
| DNS | AD DNS su DC02, forwarder AdGuard | Bassa | stesso dominio e record | Si | zone e record | Alto: record/config export da testare |
| Certificati | CA `SOC Lab Training CA`, TLS Nginx | Bassa | CA interna locale | Si | CA, certificati, private key | Alto: private key non in repo |
| Active Directory | dominio `LAB.TEST`, DC02 unico | Bassa dopo bootstrap | nuovo DC locale Windows Server 2022 | Parziale | AD/SYSVOL, gruppi, account | Critico: restore o ricreazione da validare |
| Docker | engine e bridge su VPS14 | Nessuna | Docker locale su VPS14 locale | Si | Compose, immagini, volumi | Alto: path/Compose non completamente verificati |
| PostgreSQL | 18.6, `azienda_lab`, `forgejo`, `nextcloud` | Nessuna | PostgreSQL locale compatibile | Si | dump, ruoli, grant, dati | Alto: password e dump da verificare |
| MariaDB | 10.11.14, `panel` | Nessuna | MariaDB locale compatibile | Si | dump, utenti, grant | Alto |
| Nextcloud data | files, DB, Redis/volumi | Nessuna | volumi locali e DB ripristinati | Parziale | files, DB, config | Critico: consistenza e permessi |
| Forgejo | repo, DB, allegati/config | Nessuna | container e storage locali | Parziale | Git, DB, attachments, config | Critico |
| Wazuh | Manager, Indexer, Dashboard su VPS14; due agenti | Nessuna | stesso stack su VPS14 locale | Parziale | config, enrollment, index data se richiesto | Alto |
| Pterodactyl/Wings | panel, `pteroq`, Wings | Nessuna | stessi servizi locali | Parziale | DB `panel`, config, server data | Alto |
| AdGuard | container, DNS/filter upstream | Nessuna | container locale | Si | config, filtri, liste | Medio |
| azienda-portal | Gunicorn `127.0.0.1:5000` | Nessuna | servizio locale | Parziale | codice, config, DB | Alto: dipendenze applicative da inventariare |
| Scribble | porte `8081/8082` su VPS14 | Nessuna | servizio/container locale | Parziale | config e dati | Medio |

## Blocchi di lavoro

### BLOCKER

- Inventario host/CPU/RAM/dischi e rete VMware completato.
- Collisione osservata degli IP Azure `172.16.0.4` risolta con nuova discovery.
- Regole Azure NSG e identita del public IP esportate o ricostruite.
- AD `LAB.TEST`, DNS, Kerberos, LDAP/LDAPS, Global Catalog e gruppi
  riproducibili.
- Backup testati per PostgreSQL, MariaDB, Nextcloud, Forgejo, Pterodactyl e
  volumi Docker.
- Chiavi WireGuard e private key TLS custodite fuori repository e ripristinabili.
- Wazuh Manager, agenti e canali `1514/TCP` funzionanti.
- Percorsi reali di volumi, Compose, configurazioni e storage verificati.

### IMPORTANT

- Nginx, record DNS e certificati funzionanti sui nomi `*.lab.test`.
- VPS12 unita al dominio; SSSD, Kerberos e XRDP funzionanti.
- SSH/RDP disponibili solo sul percorso VPN previsto.
- Pterodactyl, Wings, `pteroq`, portale e Scribble verificati.
- Restore ripetuto in una VM pulita con log e checksum.
- Test di perdita di un servizio e ripristino documentato.

### OPTIONAL

- Packer per immagini base dopo il primo ciclo manuale riuscito.
- Renderer dal grafo verso playbook e test.
- OpenTofu/Terraform solo dopo prova concreta del provider VMware Workstation.
- Conservazione storica di indici Wazuh non necessari al funzionamento.

## Ordine di ricostruzione derivato dal grafo

1. Creare la rete VMware equivalente all'underlay Azure.
2. Creare VPS13 e installare Windows Server 2022.
3. Creare AD DS, dominio `LAB.TEST`, DNS, Kerberos, LDAP/LDAPS, Global Catalog
   e gruppi.
4. Creare VPS14 Ubuntu Server e la rete host.
5. Configurare WireGuard hub e peer `10.10.10.0/24`.
6. Installare PostgreSQL, MariaDB e Redis.
7. Riprodurre Docker, bridge network, container e volumi.
8. Configurare Nginx, CA/certificati e record DNS.
9. Installare Wazuh Manager, Indexer e Dashboard.
10. Riprodurre Pterodactyl, Wings, `pteroq`, portale e Scribble.
11. Creare VPS12 Ubuntu Desktop, SSSD e domain join.
12. Configurare XFCE/XRDP e accesso amministrativo.
13. Installare agenti Wazuh su VPS12 e DC02.
14. Eseguire test end-to-end, poi prove di restore e migrazione dati.

L'ordine e coerente con `graph/powerseven.graph.json`; versioni, path e alcuni
legami applicativi marcati `UNVERIFIED` richiedono conferma prima di
automatizzare.

## Checklist finale prima dello shutdown

- [ ] IaC host definitions complete
- [ ] AD reproducible
- [ ] DNS reproducible
- [ ] WireGuard reproducible
- [ ] PostgreSQL migration tested
- [ ] MariaDB migration tested
- [ ] Docker services reproduced
- [ ] Forgejo data migrated
- [ ] Nextcloud data migrated
- [ ] Wazuh functional
- [ ] VPS12 joined to domain
- [ ] XRDP works
- [ ] certificates work
- [ ] end-to-end test passed
- [ ] Azure NSG/public entrypoint recorded
- [ ] backups restore-tested and checksummed
- [ ] secret references external to Git

## Informazioni ancora mancanti

- Regole effettive Azure NSG e public IP associato.
- Mappatura corretta degli indirizzi Azure VNet duplicati.
- Path e nomi reali di tutti i volumi Docker e file Compose.
- Dump recenti e restore testati di entrambi i database.
- Export AD/System State, procedura per il dominio con un solo DC e account
  necessari.
- Configurazioni LDAP di Nextcloud, Forgejo e portale.
- Inventario di certificati e private key con relativa scadenza.
- Piano di rete VMware, NAT e accesso Internet del laboratorio.
- Dati Pterodactyl server e storage Scribble.

Questi punti sono prerequisiti, non autorizzano modifiche sulle VM Azure.
