# Guida completa rebuild locale

Guida per partire da Workstation installato, ISO disponibili, repository
clonato e zero VM PowerSeven. Non usa snapshot, backup o dati Azure.

Valori target: vedere [local-architecture.md](local-architecture.md).

## Convenzioni

```text
VPS12 hostname soc-desktop, underlay 192.168.214.12, WG 10.10.10.12
VPS13 hostname DC02, underlay 192.168.214.13, WG 10.10.10.13
VPS14 hostname soc-server, underlay 192.168.214.14, WG 10.10.10.14
DOMAIN LAB.TEST, DNS 192.168.214.13, AdGuard 192.168.214.14
Infrastructure DNS: underlay `192.168.214.0/24`; application records: overlay
`10.10.10.14`.
```

Secret fuori repository:

```text
<DOMAIN_ADMIN_PASSWORD>
<DSRM_PASSWORD>
<WIREGUARD_SERVER_PRIVATE_KEY>
<WIREGUARD_PEER_PRIVATE_KEY>
<POSTGRES_ADMIN_PASSWORD>
<MARIADB_ADMIN_PASSWORD>
<WAZUH_ADMIN_PASSWORD>
<PTERODACTYL_APP_KEY>
<WINGS_TOKEN>
<CA_PRIVATE_KEY>
```

## Fase 0 — prerequisiti host

**Obiettivo:** confermare host, ISO, spazio e rete senza modifiche.

**Prerequisiti:** Workstation installato; repository clonato.

**Azioni:** verificare VMware Workstation Pro, capacità thin raccomandata di
320 GiB sotto `<VM_STORAGE_ROOT>`, ISO Ubuntu Server/Desktop e Windows Server 2022.
Verificare VMnet8 `192.168.214.0/24`, gateway `.2`, DHCP `.128-.254`.
Controllare owner host UDP `51820`; non cambiarlo.

**Configurazione attesa:** nessuna VM PowerSeven, nessun cambio VMware.

**Test:** `vmrun -T ws list` mostra zero VM PowerSeven; `ip route` non mostra
nuovi CIDR.

**Successo:** prerequisiti documentati e nessuna collisione underlay.

**Rollback:** nessuno; fase read-only.

## Fase 1 — VM vuote

**Obiettivo:** creare VPS12, VPS13, VPS14 con dischi nuovi.

**Prerequisiti:** Fase 0.

**Azioni:** creare VM sotto `<VM_STORAGE_ROOT>/PowerSeven/`, una NIC VMware NAT,
risorse minimum/recommended, ISO montata. Usare nomi VM distinti dagli
hostname. Non creare snapshot.

**Configurazione attesa:** tre VM spente o in installazione; VMDK thin.

**Test:** Workstation vede tre VM; NIC collegate a VMnet8; capacità disco
corrette.

**Successo:** tre VM avviabili, nessun servizio applicativo.

**Rollback:** spegnere e rimuovere solo VM nuove non ancora configurate.

## Fase 2 — OS bootstrap

**Obiettivo:** installare OS base.

**Prerequisiti:** Fase 1; ISO.

**Azioni:** installare Ubuntu Desktop su VPS12, Windows Server 2022 su VPS13,
Ubuntu Server su VPS14. Impostare hostname, locale, timezone, account
amministrativo e SSH/OpenSSH previsto. DNS temporaneo `192.168.214.2`.

**Configurazione attesa:** OS aggiornabile e raggiungibile sull'underlay; nessun
join dominio.

**Test:** console/SSH, `hostname`, route default, DNS query esterna.

**Successo:** tre OS puliti con hostname corretti.

**Rollback:** reinstallare singola VM, senza coinvolgere altre.

## Fase 3 — underlay statico

**Obiettivo:** rete comune stabile.

**Prerequisiti:** OS bootstrap.

**Azioni:** impostare `192.168.214.12`, `.13`, `.14`, gateway `.2`; riservare
gli IP fuori DHCP. Mantenere resolver `.2` finché DC02 non è pronto.

**Configurazione attesa:** VM comunicano su VMnet8 e raggiungono Internet via
NAT.

**Test:** ping tra tre VM, `ip route`/`Get-NetIPConfiguration`, DNS esterno.
Verificare che VPS12/VPS14 usino DC02 `192.168.214.13`; non usare ancora
record applicativi overlay per il bootstrap.

**Successo:** underlay bidirezionale e indirizzi stabili.

**Rollback:** ripristinare DHCP/statico della sola VM interessata.

## Fase 4 — nuovo DC02

**Obiettivo:** identità e DNS autorevole nuovi.

**Prerequisiti:** VPS13 Fase 3.

**Azioni:** installare ruoli AD DS/DNS; creare nuovo forest/domain `LAB.TEST`
con `<DOMAIN_ADMIN_PASSWORD>` e `<DSRM_PASSWORD>`; creare gruppi
`SOC-Desktop-Users`, `SOC-Web-Users` e utenti minimi. Configurare forwarder
temporaneo `192.168.214.2`. Non installare AD CS.

**Configurazione attesa:** DC02 `192.168.214.13`, DNS zone `lab.test`,
`_msdcs.lab.test`, Kerberos, LDAP, Global Catalog.

**Test:** `Get-ADDomain`, `Get-DnsServerZone`, `Resolve-DnsName`, `klist`,
LDAP bind locale.

**Successo:** dominio nuovo risolve record DC e query Internet tramite
forwarder temporaneo.

**Rollback:** demote/remove il nuovo DC locale e reinstallare VPS13; Azure
non è parte del rollback.

## Fase 5 — VPS14, Docker e AdGuard

**Obiettivo:** nuovo resolver/filter locale.

**Prerequisiti:** Fase 3; DC02 può restare con forwarder temporaneo.

**Azioni:** installare Docker, creare reti dichiarate, installare AdGuard con
config vuota, bind DNS su `192.168.214.14:53`, UI su loopback. Impostare
upstream Internet temporaneo.

**Configurazione attesa:** AdGuard risponde senza dipendere da DC02.

**Test:** query A/AAAA verso `192.168.214.14`, health UI, query Internet.

**Successo:** resolver locale stabile.

**Rollback:** rimuovere solo configurazione/container AdGuard nuovi.

## Fase 6 — DNS finale

**Obiettivo:** catena DNS definitiva senza ciclo.

**Prerequisiti:** AdGuard health check passato.

**Azioni:** cambiare forwarder DC02 a `192.168.214.14`; impostare VPS12/VPS14
resolver primario `192.168.214.13`; creare `dc02.lab.test` verso
`192.168.214.13` e i record applicativi `cloud`, `git`, `pdf`, `login`, `panel`,
`wazuh`, `adguard`, `wings`, `scribble*` verso `10.10.10.14`.

**Configurazione attesa:** client e servizi usano DC02; DC02 inoltra ad
AdGuard; AdGuard inoltra Internet.

**Test:** risoluzione interna/esterna da tutte le VM; `_ldap._tcp`, `_kerberos`.

**Successo:** DNS interno e Internet funzionanti.

**Rollback:** riportare temporaneamente forwarder DC02 a `192.168.214.2`.

## Fase 7 — WireGuard

**Obiettivo:** overlay `10.10.10.0/24` nuovo.

**Prerequisiti:** underlay stabile; UDP owner deciso.

**Azioni:** generare nuove chiavi; configurare VPS14 `10.10.10.14/24` e solo i
peer VM VPS12/VPS13 `.12/.13`; abilitare forwarding tra peer. Il client host
`.101` resta sul profilo Azure e non viene collegato al nuovo hub.
Verificare unit reale installata; non assumere `wireguard@wg-final`.

**Configurazione attesa:** hub VPS14, AllowedIPs minimi, UDP 51820.

**Test:** handshake tra le tre VM, ping `.12/.13/.14`, accesso DNS underlay e
HTTPS via tunnel. Il test client `.101` è esclusivamente WG-03 di cutover.

**Successo:** peer autorizzati comunicano; peer non autorizzati no.

**Rollback:** disabilitare/rimuovere solo config WireGuard locale nuova.

## Automazione futura per fase

| Fase | Componente IaC futuro |
|---|---|
| 0 | `iac/vmware/` e `iac/validation/preflight` |
| 1 | creazione manuale VMware GUI + `iac/vmware/validate-vms` |
| 2 | `iac/linux/autoinstall/`, `iac/windows/autounattend.xml` |
| 3 | `iac/linux/cloud-init/`, `iac/windows/bootstrap.ps1` |
| 4-6 | Ansible `ad_ds`, `dns`, `adguard` |
| 7 | Ansible `wireguard` + acceptance WG-01/WG-02 |
| 8-9 | Ansible database/CA + `iac/docker/compose.yml` |
| 10-11 | ruoli Ansible `pterodactyl_panel`, `wings`, `pteroq`, `nginx`, `portal`, `scribble` |
| 12-13 | ruoli `wazuh_server`, `wazuh_agent*`, `xrdp`, `sssd` |
| 14-15 | `iac/validation/` + acceptance E2E; WG-03 solo cutover |

## Fase 8 — CA e database vuoti

**Obiettivo:** TLS e backend dati nuovi.

**Prerequisiti:** DNS finale; VPS14 operativo.

**Azioni:** creare nuova CA con `<CA_PRIVATE_KEY>` custodita fuori Git; emettere
certificati Nginx e LDAPS. Installare PostgreSQL, MariaDB, Redis; creare DB
vuoti `azienda_lab`, `forgejo`, `nextcloud`, `postgres`, `panel` e ruoli nuovi.

**Configurazione attesa:** nessun vecchio dump, volume o chiave importata.

**Test:** listener, login con secret ref, `openssl s_client` LDAPS.

**Successo:** DB vuoti e TLS verificabile.

**Rollback:** rimuovere solo DB/certificati locali appena creati.

## Fase 9 — applicazioni base

**Obiettivo:** servizi applicativi freschi.

**Prerequisiti:** Docker, database, LDAP/LDAPS, cert.

**Azioni:** deployare Nextcloud, Forgejo, Stirling PDF, azienda-portal e
Scribble con config nuova. `azienda-portal` è la dashboard CORE e deve essere
installato/configurato prima dell'abilitazione di `powerseven-core.target`.
Creare nuovi volumi; non copiare volumi Azure.
Configurare LDAP/LDAPS e connessioni DB con placeholder.

**Configurazione attesa:** backend loopback/Docker, DNS names `*.lab.test`.

**Test:** health endpoint locali, login LDAP di test, schema DB creati.

**Successo:** app inizializzate senza dati precedenti.

**Rollback:** rimuovere solo stack/volumi nuovi della singola app.

## Fase 10 — Pterodactyl

**Obiettivo:** Panel, Wings, `pteroq` senza ciclo.

**Prerequisiti:** MariaDB vuoto; DNS/TLS.

**Azioni:** installare Panel e schema DB; generare `<PTERODACTYL_APP_KEY>`;
configurare Wings con `<WINGS_TOKEN>` ottenuto dal nuovo Panel; avviare Wings;
configurare e avviare `pteroq`.

**Configurazione attesa:** Panel installabile senza Wings; Wings e `pteroq`
partono dopo configurazione Panel; runtime comunica con Panel.

**Test:** Panel login, queue healthy, Wings registration/API/SFTP.

**Successo:** Panel/Wings/queue operativi; nessun ciclo provisioning.

**Rollback:** fermare e rimuovere solo servizi Pterodactyl nuovi.

## Fase 11 — Nginx e firewall

**Obiettivo:** pubblicazione controllata.

**Prerequisiti:** app health check, cert e DNS.

**Azioni:** configurare Nginx per ogni hostname; firewall: SSH/RDP/XRDP via
WireGuard, HTTP/HTTPS secondo policy, DB non pubblici, Wazuh porte necessarie.

**Configurazione attesa:** Nginx termina TLS e proxy passa ai backend corretti.

**Test:** `curl`, certificate SAN, status code, scansione porte da underlay e
overlay autorizzati.

**Successo:** solo superfici previste raggiungibili.

**Rollback:** ripristinare config Nginx/firewall della sola fase.

## Fase 12 — Wazuh

**Obiettivo:** monitoraggio nuovo senza storico.

**Prerequisiti:** Docker/runtime, WireGuard, DNS.

**Azioni:** installare Manager, Indexer, Dashboard con credenziali nuove;
configurare cert nuovi; pubblicare Dashboard via Nginx.

**Configurazione attesa:** indici vuoti, Manager su 1514/1515, API 55000.

**Test:** Dashboard, enrollment, evento test.

**Successo:** Manager vede agenti nuovi.

**Rollback:** rimuovere solo stack Wazuh nuovo e suoi indici vuoti.

## Fase 12A — service profiles e Cockpit

**Obiettivo:** boot CORE-only e applicazioni indipendenti con dipendenze condivise.

**Prerequisiti:** Docker, servizi host e applicazioni installati; unità
WireGuard locale verificata; nessun secret nel repository.

**Azioni:** renderizzare `iac/service-control/systemd/`, impostare il nome
reale dell'unità WireGuard, configurare `restart: "no"` nei Compose, abilitare
solo `powerseven-core.target`, installare Cockpit e socket activation in una
fase separata, quindi applicare Polkit dopo il test con un account non-sudo.

**Configurazione attesa:** boot = CORE; CORE contiene WireGuard, SSH, Nginx,
dashboard azienda-portal AD-only, AdGuard, Cockpit socket e Docker. PostgreSQL,
MariaDB, Redis e PHP-FPM sono dipendenze condivise on demand; il controller
ricalcola ogni volta l'unione delle dipendenze delle applicazioni attive.

La dashboard PowerSeven resta la GUI principale (`login.lab.test` via Nginx).
Cockpit su `https://10.10.10.14:9090` è la GUI tecnica; non creare un plugin
Cockpit custom. L’accesso è limitato alla VPN, con Polkit per
`powerseven-operators`.

**Test:** avviare ogni profilo da Cockpit, verificare stop del precedente,
CORE invariato, RAM/CPU, health check e kill switch. Non eseguire questa fase
su Azure durante la discovery.

## Fase 13 — VPS12 e domain join

**Obiettivo:** desktop SOC operativo.

**Prerequisiti:** AD/DNS/Kerberos/LDAP, WireGuard, cert trust.

**Azioni:** installare XFCE/XRDP/SSSD; configurare `LAB.TEST`; usare
`<DOMAIN_ADMIN_PASSWORD>` solo in secret store/interattivo; consentire gruppo
`SOC-Desktop-Users`; installare Wazuh Agent.

**Configurazione attesa:** `soc-desktop` joined; XRDP e SSH policy corretti.

**Test:** `realm list`, `kinit`, login XRDP AD, Wazuh agent online.

**Successo:** login AD via XRDP e telemetria.

**Rollback:** leave domain e rimuovere config SSSD locale; reinstallare solo
VPS12 se necessario.

## Fase 14 — DC02 agent e integrazione

**Obiettivo:** chiudere osservabilità e policy.

**Prerequisiti:** Wazuh Manager; DC02 funzionante.

**Azioni:** installare/configurare Wazuh Agent su DC02; verificare Windows
Firewall, RDP, OpenSSH e DNS records.

**Configurazione attesa:** due agenti online, policy firewall dichiarata.

**Test:** evento da DC02, RDP, SSH e DNS.

**Successo:** DC02 e VPS12 monitorati.

**Rollback:** disinstallare solo agent/config nuova su DC02.

## Fase 15 — Nginx e test finale

**Obiettivo:** equivalenza funzionale end-to-end.

**Prerequisiti:** tutte fasi precedenti.

**Azioni:** eseguire [local-acceptance-tests.md](local-acceptance-tests.md),
registrare comando, risultato e timestamp. Testare anche client `.101` da
macchina esterna o ambiente isolato; non usare la route host `giorgio` come
prova automatica.

**Configurazione attesa:** laboratorio nuovo, nessun dato storico.

**Test:** checklist completa.

**Successo:** ogni test PASS; report ripetibile.

**Rollback:** correggere la fase fallita; nessun rollback Azure.
