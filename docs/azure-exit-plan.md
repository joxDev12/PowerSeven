# Azure exit plan e nuovo scope locale

Questa fase progetta un laboratorio locale nuovo. Non esegue backup, restore,
migrazione dati, snapshot, provisioning VMware o modifiche Azure.

Azure resta acceso finché il rebuild locale vuoto supera
[local-acceptance-tests.md](local-acceptance-tests.md).

## Correzione modello Azure

| Host | VNet | Address space | Subnet | Private IP | Peering |
|---|---|---|---|---|---|
| VPS12 | `vnet-austriaeast-1` | `172.16.0.0/16` | `172.16.0.0/24` | `172.16.0.4` | No |
| VPS13 | `vnet-belgiumcentral-2` | `172.16.0.0/16` | `172.16.0.0/24` | `172.16.0.4` | No |
| VPS14 | `vnet-denmarkeast-1` | `172.16.0.0/16` | `172.16.0.0/24` | `172.16.0.4` | No |

La ripetizione di `172.16.0.4` non era una collisione: le VNet erano tre
domini di rete distinti. Il locale usa una sola underlay VMware; non replica
le VNet regionali.

## Scope

### Ricreabile, in scope

VM, OS, CPU/RAM/dischi dichiarati, rete VMware NAT, overlay WireGuard, AD DS,
dominio `LAB.TEST`, utenti/gruppi, DNS, Kerberos, LDAP/LDAPS, SSH, RDP, XRDP,
SSSD, Nginx, Docker, PostgreSQL, MariaDB, Redis, Nextcloud, Forgejo, Stirling
PDF, AdGuard, Wazuh, Pterodactyl, Wings, `pteroq`, azienda-portal, Scribble,
nuova CA/certificati, firewall e test end-to-end.

Tutti i database, volumi, indici e configurazioni applicative partono vuoti.

### Stato persistente, fuori scope

- backup e restore database;
- migrazione file Nextcloud;
- migrazione repository/allegati Forgejo;
- storico Wazuh e vecchi indici;
- snapshot Azure o VMware;
- restore AD/System State;
- vecchie chiavi WireGuard e vecchi certificati;
- copia volumi Docker;
- qualsiasi dato applicativo precedente.

Il catalogo resta in [`iac/inventory/storage.yml`](../iac/inventory/storage.yml)
per distinguere stato ricreabile da stato escluso.

## Gap Azure verso locale

| Componente | Stato attuale | Dipendenza Azure | Equivalente locale | Automatizzabile | Stato dati | Rischio |
|---|---|---|---|---|---|---|
| Tre VNet | tre VNet isolate, CIDR ripetuti | underlay Azure | una VMnet NAT comune | Sì | nessun dato | Basso |
| Public IP | endpoint WireGuard Azure | IP/NAT Azure | port-forward host o OPNsense verso `192.168.214.14:51820` | Parziale | nuova configurazione | Alto |
| NSG | filtro cloud per VNet | enforcement Azure | firewall host + regole VMware/upstream | Parziale | nuove regole | Alto |
| Dischi VM | dischi OS Azure | storage Azure | VMDK locali thin | Sì | dischi nuovi | Medio |
| Hostname | `soc-desktop`, `DC02`, `soc-server` | Nessuna | stessi hostname | Sì | nuovo OS | Basso |
| IP WireGuard | `.12`, `.13`, `.14`, client `.101-.107` | Solo endpoint hub | stessi IP overlay | Sì | nuove chiavi | Medio |
| DNS | AD DNS + forwarder AdGuard | Solo reachability | nuovo DNS AD + nuovo AdGuard | Sì | zone nuove | Alto |
| Certificati | CA lab esistente | Nessuna | nuova CA lab e nuovi cert | Sì | chiavi nuove | Medio |
| Active Directory | DC02, `LAB.TEST` | VM Azure | nuovo forest/domain controller | Parziale | directory vuota | Critico |
| Docker | engine, bridge, container | VM/storage Azure | Docker nuovo su VPS14 | Sì | volumi vuoti | Medio |
| PostgreSQL | version/config/database osservati | VM/storage Azure | installazione nuova | Sì | database vuoti | Medio |
| MariaDB | version/config/database osservati | VM/storage Azure | installazione nuova | Sì | database vuoto | Medio |
| Redis | locale + container Nextcloud | VM/storage Azure | installazione/Compose nuova | Sì | cache vuota | Basso |
| Nextcloud | servizio applicativo | VM/storage Azure | installazione nuova | Parziale | nessun file/DB migrato | Medio |
| Forgejo | servizio applicativo | VM/storage Azure | installazione nuova | Parziale | nessun repo/DB migrato | Medio |
| Wazuh | Manager/Indexer/Dashboard | VM/storage Azure | stack nuovo | Parziale | storico vuoto | Medio |
| Pterodactyl/Wings | Panel, worker, daemon | VM/storage Azure | installazione nuova senza server data | Parziale | DB/config vuoti | Alto |
| AdGuard | DNS/filter container | VM/storage Azure | container nuovo | Sì | config nuova | Medio |
| azienda-portal | servizio Gunicorn | VM/storage Azure | servizio nuovo | Parziale | DB/config vuoti | Alto |
| Scribble | servizi su 8081/8082 | VM/storage Azure | servizio/container nuovo | Parziale | dati vuoti | Medio |

## BLOCKER prima dell'automazione

- [ ] Architettura VMware `192.168.214.0/24` approvata; nessun conflitto
      host/Docker confermato.
- [ ] Conflitto operativo dell'overlay host `giorgio` gestito in fase di test
      senza alterarlo ora.
- [ ] ISO Ubuntu Server/Desktop e Windows Server 2022 disponibili.
- [ ] Nuovo dominio `LAB.TEST`, utenti, gruppi e GPO minime definiti.
- [ ] DNS bootstrap temporaneo e passaggio finale ad AdGuard testati.
- [ ] Nome unit WireGuard verificato durante implementazione; modello non lo
      assume.
- [ ] AD CS non incluso: aggiungere solo con evidenza reale e requisito.
- [ ] Pterodactyl, Wings e `pteroq` separati tra configurazione, runtime e
      provisioning; nessun ciclo nell'ordine.
- [ ] Nuova CA e certificati lab generabili senza vecchie chiavi.
- [ ] Test di accettazione completo passato.

## IMPORTANT

- [ ] Versioni applicative e immagini fissate.
- [ ] Configurazioni Compose, Nginx, firewall e systemd descritte.
- [ ] Secret store esterno pronto con riferimenti come
      `<DOMAIN_ADMIN_PASSWORD>` e `<WIREGUARD_PRIVATE_KEY>`.
- [ ] Policy accesso: UDP 51820 pubblico solo se richiesto; SSH/RDP/XRDP via
      overlay o policy esplicita.
- [ ] Percorsi locali VMDK scelti su filesystem con spazio sufficiente.

## OPTIONAL

- [ ] Packer per template OS dopo un rebuild manuale riuscito.
- [ ] Renderer automatico dal grafo verso Ansible/PowerShell/Compose.
- [ ] vSphere/ESXi futuro per valutare OpenTofu/Terraform.
- [ ] Secondo DC o rete locale ridondata.

## Criterio di shutdown Azure

Non serve migrare lo stato Azure per questo target. Azure può essere spento
solo dopo che il laboratorio locale vuoto ricrea infrastruttura, identità,
rete, servizi e flussi end-to-end definiti nei test di accettazione.
