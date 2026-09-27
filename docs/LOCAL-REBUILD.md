# PowerSeven — local rebuild

Punto d'ingresso per ricreare il laboratorio locale su VMware Workstation Pro.
Questa procedura replica il laboratorio attuale con dati nuovi; non importa
Azure, vecchi volumi, vecchie chiavi WireGuard o lo stato AD esistente.

La creazione delle VM resta manuale dalla GUI VMware. `vmrun` è ammesso solo
per lifecycle/verifica di VM già create. Terraform/OpenTofu non fanno parte del
workflow.

## Target approvato

| VM | Nome VMware | Hostname | Guest | vCPU | RAM | Disco thin | Rete/IP |
|---|---|---|---|---:|---:|---:|---|
| VPS12 | `PowerSeven-VPS12` | `soc-desktop` | Ubuntu Desktop 24.04.x | 2 | 2 GiB | 80 GiB | VMnet8 / `192.168.214.12` |
| VPS13 | `PowerSeven-VPS13` | `DC02` | Windows Server 2022 Datacenter Desktop Experience | 2 | 3 GiB | 60 GiB | VMnet8 / `192.168.214.13` |
| VPS14 | `PowerSeven-VPS14` | `soc-server` | Ubuntu Server 24.04.x | 4 | 5 GiB | 120 GiB | VMnet8 / `192.168.214.14` |

VMnet8: `192.168.214.0/24`, gateway `192.168.214.2`. L'overlay WireGuard
resta `10.10.10.0/24`; non va configurato durante il bootstrap iniziale.

Totale allocato: 8 vCPU, 10 GiB RAM, 260 GiB thin. L'host deve avere ulteriore
margine per Workstation e il sistema operativo.

## Stati

- **READY**: artefatto eseguibile o validatore read-only già presente e
  verificabile.
- **PARTIAL**: template o comando presente, ma richiede passaggi manuali,
  decisioni o componenti non implementati.
- **MISSING**: non esiste ancora un'implementazione riproducibile.

“Eseguibile” qui non significa “già eseguito”: nessuna fase di questo documento
provisiona VM o host automaticamente.

## Workflow checkpoint

### PHASE 0 — host preflight

- **Modalità:** automatizzabile, read-only.
- **Comando:**
  `iac/vmware/preflight-host --storage-root <VM_STORAGE_ROOT> --ubuntu-desktop-iso <UBUNTU_DESKTOP_ISO> --ubuntu-server-iso <UBUNTU_SERVER_ISO> --windows-server-iso <WINDOWS_SERVER_2022_ISO>`
- **Prerequisiti:** VMware Workstation Pro, ISO leggibili, almeno 260 GiB
  liberi nel percorso scelto, VMnet8 già presente.
- **Risultato atteso:** capability VMware, spazio, ISO, VMnet8/gateway e
  collisioni IP controllati; nessuna VM o rete modificata.
- **Stato:** **READY**. Un WARN mantiene l'esito non-PASS; un FAIL blocca il
  checkpoint successivo.

### PHASE 1 — creazione manuale VM

- **Modalità:** manuale, GUI VMware Workstation Pro.
- **Comando:** nessuno nel repository; non usare un create-vm script.
- **Prerequisiti:** PHASE 0 PASS; specifica sopra; ISO appropriate.
- **Risultato atteso:** tre VM con i nomi, risorse, dischi thin e una NIC su
  VMnet8; VM spente prima della validazione.
- **Stato:** **READY** come procedura manuale.

### PHASE 2 — validate-vms

- **Modalità:** automatizzabile, read-only.
- **Comando:**
  `iac/vmware/validate-vms --paths-file iac/vmware/manual-vm-paths.yml`
- **Prerequisiti:** PHASE 1 completata; copia locale di
  `iac/vmware/manual-vm-paths.example.yml` con path VMX e ISO reali.
- **Risultato atteso:** nome, vCPU, RAM, guest type, NIC VMnet8, capacità
  VMDK, ISO e stato spento verificati per tutte le VM.
- **Stato:** **READY**. Il file dei path è locale e ignorato da Git.

### PHASE 3 — installazione/bootstrap OS

- **Modalità:** installazione manuale con template; bootstrap parzialmente
  automatizzabile.
- **Comandi previsti:** autoinstall usa i file
  `iac/linux/autoinstall/vps12-user-data.yaml` e
  `iac/linux/autoinstall/vps14-user-data.yaml`; su Windows il dry-run reale è
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File iac/windows/bootstrap.ps1 -Check`.
- **Prerequisiti:** PHASE 2 PASS; placeholder risolti in workspace locale;
  password e chiavi fuori Git.
- **Risultato atteso:** Ubuntu Desktop/Server e Windows Server 2022 Desktop
  Experience installati con hostname e SSH/OpenSSH iniziali.
- **Stato:** **PARTIAL**. I template Linux non hanno ancora renderer/installer
  orchestrato; il bootstrap Windows è invece disponibile a checkpoint, ma non è
  stato eseguito su VPS13 live da questa macchina.

### PHASE 4 — rete/IP underlay

- **Modalità:** manuale/partially automatizzabile.
- **Comandi previsti:** su Linux verificare `ip addr` e `ip route`; su Windows
  il checkpoint VPS13 usa `bootstrap.ps1 -Apply -Checkpoint 2`, mentre
  `Get-NetIPConfiguration` resta la verifica manuale. Linux non ha ancora un
  apply idempotente repository.
- **Prerequisiti:** OS installato; VMnet8/gateway validati.
- **Risultato atteso:** `.12/.13/.14` statici su `192.168.214.0/24`, gateway
  `.2`, DNS bootstrap `1.1.1.1`/`8.8.8.8`; nessun conflitto con LAN o bridge
  Docker.
- **Stato:** **PARTIAL**. Gli indirizzi sono dichiarati in YAML/autoinstall e
  nel bootstrap PowerShell, ma l'interfaccia reale resta da selezionare.

### PHASE 5 — VPS13 AD/DNS

- **Modalità:** automatizzabile a checkpoint su VPS13; reboot manuali.
- **Comandi reali, da PowerShell Administrator su VPS13:**
  `.\bootstrap.ps1 -Check`, poi `.\bootstrap.ps1 -Apply -Checkpoint 1` fino a
  `7`; dopo ogni reboot si riprende dal checkpoint indicato. La validazione
  finale è `.\validate-vps13.ps1`.
- **Prerequisiti:** VPS13 con rete underlay; secret DSRM/domain admin forniti
  localmente.
- **Risultato atteso:** nuovo forest `LAB.TEST`, DNS, Kerberos, LDAP,
  Global Catalog, utenti/gruppi minimi e forwarder Internet iniziale
  `1.1.1.1`/`8.8.8.8`.
- **Stato:** **PARTIAL / NEEDS_LIVE_TEST**. `bootstrap.ps1` rileva lo stato,
  installa AD DS/DNS, promuove una nuova forest senza seconda promozione,
  configura DNS, utenti/gruppi e record in modo idempotente. La verifica
  reale richiede ancora una VPS13 Windows.

#### Checkpoint VPS13

| Checkpoint | Automatico | Manuale/reboot | Verifica |
|---|---|---|---|
| 1 base Windows | OS, Datacenter, Desktop Experience, OpenSSH, PSRemoting | nessun reboot normalmente | `bootstrap.ps1 -Check -Checkpoint 1` |
| 2 hostname/rete | `DC02`, `192.168.214.13/24`, gateway `192.168.214.2`, DNS bootstrap `1.1.1.1`/`8.8.8.8` | reboot manuale dopo Rename-Computer; passare `-InterfaceAlias` se necessario | `Get-NetIPConfiguration` |
| 3 AD DS install | feature AD DS + DNS | se restituisce `REBOOT_REQUIRED`: reboot, rieseguire checkpoint 3 | `Get-WindowsFeature` |
| 4 forest/domain | nuova forest `LAB.TEST`, NetBIOS `LAB` | DSRM con prompt SecureString; reboot manuale dopo promozione | `Get-ADDomain`, `Get-ADForest` |
| 5 DNS | zona AD-integrated, `_msdcs`, forwarder `1.1.1.1`/`8.8.8.8`, client `192.168.214.13` | nessun reboot previsto | `Get-DnsServerZone`, `Get-DnsServerForwarder` |
| 6 gruppi/utenti | gruppi automatici; utenti definiti dall'installatore | password solo prompt interattivo | `Get-ADUser`, `Get-ADGroup` |
| 7 record | record A dichiarati, senza duplicare quelli corretti | nessun reboot | `Get-DnsServerResourceRecord` |
| 8 validation | nessuna modifica | nessun reboot | `validate-vps13.ps1` |

`-Apply -Checkpoint 8` è rifiutato intenzionalmente: la validation è sempre
read-only. Il workflow non promuove una macchina già DC o già appartenente a un
dominio diverso.

Checkpoint 6 crea automaticamente solo i quattro gruppi PowerSeven. Il file
tracciato `iac/windows/users.psd1` contiene `Users = @()`: nessun account
personale è incluso nel clone. `-Apply -Checkpoint 6` chiede oggi all'installatore
se vuole creare utenti e raccoglie nome, cognome, username, gruppi e password
interattivamente. La funzione `Ensure-PowerSevenUser` è separata dalla UI e può
essere riusata da un runner futuro con un `users.local.psd1` ignorato da Git;
le password non vengono versionate.

### PHASE 6 — VPS14 servizi base

- **Modalità:** manuale con dichiarazioni riutilizzabili.
- **Comandi previsti:** nessun apply repository; dopo bootstrap il controllo
  statico Compose è `docker compose config` usando un `.env` locale completo.
- **Prerequisiti:** VPS14 underlay, DC02/DNS funzionante, Docker e secret locali.
- **Risultato atteso:** Docker, reti, AdGuard vuoto, PostgreSQL/MariaDB/Redis
  secondo i consumatori, Nginx e dashboard AD-only.
- **Stato:** **PARTIAL**. `iac/docker/compose.yml` è un catalogo dichiarativo
  con immagini/secret placeholder e non contiene il servizio cron Nextcloud;
  i role Ansible applicativi sono contratti. Non esiste installazione
  riproducibile di dashboard, Nginx, database o AdGuard.

### PHASE 7 — VPS12 desktop/client

- **Modalità:** manuale con automazione futura.
- **Comandi previsti:** template autoinstall; verifiche `realm list`, `klist` e
  XRDP dopo configurazione.
- **Prerequisiti:** AD/DNS/Kerberos/LDAP e WireGuard disponibili; chiavi SSH e
  secret join locali.
- **Risultato atteso:** XFCE/XRDP/SSSD, join `LAB.TEST`, accesso gruppo SOC,
  Wazuh Agent.
- **Stato:** **MISSING** per rebuild. Autoinstall dichiara il bootstrap, ma i
  role `sssd`, `xrdp` e agent sono solo README contract.

### PHASE 8 — WireGuard/DNS/CA

- **Modalità:** manuale controllata; automazione mancante.
- **Comandi previsti:** nessun generator repository. Le verifiche finali
  previste sono `sudo wg show`, `dig`, `openssl s_client` e i test DNS della
  suite `docs/local-acceptance-tests.md`.
- **Prerequisiti:** underlay stabile, owner UDP 51820 deciso, secret store
  locale.
- **Risultato atteso:** nuove chiavi, hub `.14`, peer VM `.12/.13`, DNS finale
  DC02 → AdGuard e CA nuova per TLS/LDAPS.
- **Stato:** **MISSING** per provisioning. Esistono inventory e role contract,
  ma non generatori di chiavi/CA, apply WireGuard, utenti/gruppi DNS o record.

### PHASE 9 — service-control

- **Modalità:** installazione manuale oggi; validazione automatizzabile.
- **Comandi:** `python3 iac/service-control/validate.py` e, dopo un'installazione
  manuale delle unità, uso delle unità `iac/service-control/systemd/` tramite
  systemd/Cockpit.
- **Prerequisiti:** servizi reali già installati; nome locale WireGuard e
  container/porte verificati.
- **Risultato atteso:** boot CORE-only, applicazioni indipendenti, dipendenze
  union-based, PostgreSQL non CORE e stato `/run/powerseven` ricostruibile.
- **Stato:** **PARTIAL**. Controller, unit template e validator sono reali;
  manca l'installazione/configurazione idempotente delle unità e dei servizi
  sottostanti.

### PHASE 10 — acceptance test

- **Modalità:** manuale con validator statici.
- **Comandi:** `python3 iac/validation/preflight`,
  `python3 iac/service-control/validate.py` e i comandi indicati in
  `docs/local-acceptance-tests.md`.
- **Prerequisiti:** tutte le fasi operative completate e secret risolti fuori
  repository.
- **Risultato atteso:** NET/WG/DNS/identity, accesso, database, Docker,
  applicazioni, Pterodactyl, Wazuh, firewall ed E2E PASS.
- **Stato:** **PARTIAL**. La suite è documentata; non esiste ancora un runner
  E2E e molte superfici dipendono dai provisioner mancanti.

## Audit di `iac/`

| Area | Classificazione | Evidenza reale |
|---|---|---|
| `iac/vmware/` | A + B | `preflight-host` e `validate-vms` sono read-only eseguibili; YAML e path example sono dichiarativi. Creazione VM intenzionalmente assente. |
| `iac/linux/` | B/C | autoinstall e variables sono template con placeholder; README dichiara che non vengono applicati automaticamente. |
| `iac/windows/` | A parziale + B | `bootstrap.ps1` implementa checkpoint 1-8 e `validate-vps13.ps1` è read-only; `autounattend.xml` resta input installer. Esecuzione live non ancora verificata. |
| `iac/ansible/` | A limitata + B/C | playbook e inventory sono invocabili come struttura; `check.yml` è un check contract; solo `roles/wazuh_server/tasks/main.yml` contiene task reali, gli altri role sono README. |
| `iac/docker/` | B/C | Compose è dichiarativo e usa immagini/secret placeholder; non è un deployment completo né include tutti i servizi live. |
| `iac/service-control/` | A runtime/static + B | controller Python e validator sono eseguibili; unità systemd e YAML sono template di installazione, non un installer. |
| `iac/validation/` | A read-only | `preflight` controlla YAML/JSON, grafo, rete, secret pattern, cicli, porte, VM e Compose. |
| `iac/inventory/` | B | cataloghi dichiarativi di host, rete, DNS, servizi, storage e ordine; nessun apply. |
| `iac/versions.yml` | B/C | matrice di policy; molte versioni e checksum sono ancora `REQUIRED_DECISION`. |

## Gap matrix

| Componente | Stato attuale | Mancante | Prossima implementazione |
|---|---|---|---|
| VM VMware | GUI + validator read-only | nessun create API, per scelta | checklist GUI e usare `validate-vms` |
| Ubuntu bootstrap | autoinstall template | renderer/seed e post-bootstrap apply | renderer minimo per placeholder, poi test su VM |
| Windows provisioning | workflow PowerShell checkpoint 1-8 | test live, integrazione Ansible e firewall policy completa | eseguire su VPS13 e poi wrapper Ansible |
| Ansible | inventory/playbook/contratti | task per tutti i role eccetto tuning Wazuh | implementare un role per checkpoint |
| Docker Compose | servizi dichiarati, `restart: no` | tag approvati, `.env`, cron Nextcloud, config/volumi live | chiudere immagini e deployment per app |
| CA/TLS | riferimenti e contratti | generazione CA/certificati e trust | generatore locale escluso da Git |
| AD users/groups | gruppi automatici + utenti interattivi al checkpoint 6 | test live; manifest locale non ancora orchestrato | eseguire checkpoint 6; mantenere password interattive |
| DNS records | `iac/windows/provisioning.psd1` + checkpoint 5/7 | test live; forwarder finale AdGuard resta successivo | eseguire checkpoint 5/7 e validatore |
| service-control | controller/unit/validator | installazione idempotente e naming locale | installer per sole unit allowlisted |
| dashboard | servizio/health/runtime AD-only descritti | provisioning sorgente/config/Nginx | role dashboard senza PostgreSQL |
| Wazuh | tuning Indexer reale; altri contratti | package/TLS/Manager/Dashboard/agent | role incrementali fresh-install |
| Pterodactyl | dependency map/unità/contratti | Panel, MariaDB, Wings, pteroq provisioning | checkpoint Panel → Wings → queue |
| Forgejo | Compose e controller runtime | immagine/config/DB/LDAP deployment | role app + health |
| Nextcloud | Compose/controller model | cron/config/DB/Redis/LDAP deployment | role app + health |
| Stirling | Compose/controller model | immagine/config/deployment | role app + health |
| Secrets | `REQUIRED_SECRET`, `REQUIRED_DECISION` | secret store/vault e renderer | usare `iac/docker/.env` locale ignorato; Vault in seguito |
| Acceptance | suite documentata + static validators | runner E2E/reporting | aggiungere solo dopo i provisioner |

## Secret boundary

Nel repository restano solo riferimenti logici. Il collega fornisce localmente
password, token, chiavi WireGuard, chiavi private CA/certificati, credenziali
database e chiavi SSH. Il file `iac/docker/.env` è ignorato da Git; i path VM
locali restano in `iac/vmware/*.local.yml` o nel file ignorato
`iac/vmware/manual-vm-paths.yml`. Ansible Vault è una fase successiva.

## Ordine consigliato dei lavori mancanti

1. chiudere decisioni versioni/ISO e validare le tre VM;
2. completare bootstrap OS e underlay statico;
3. eseguire e validare DC02 AD/DNS con i checkpoint PowerShell;
4. implementare VPS14 base, AdGuard, Docker, database e CA;
5. implementare WireGuard/DNS finale e trust;
6. implementare un'applicazione per volta: dashboard, Forgejo, Nextcloud,
   Stirling, Pterodactyl, Wazuh;
7. installare service-control e solo dopo eseguire acceptance E2E.

Ogni punto deve avere check-mode/read-only, apply limitato al proprio host e
un test di health separato. Non creare un `install-all`.
