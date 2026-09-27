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
| VPS14 | `PowerSeven-VPS14` | `soc-server` | Ubuntu Server 24.04.x | 4 | 5 GiB | 40 GiB | VMnet8 `.14` + Bridged DHCP |

VMnet8: `192.168.214.0/24`, gateway `192.168.214.2`; VPS14 usa DNS DC02
`192.168.214.13`. La NIC Bridged usa DHCP senza default route né DNS. Il VPN
amministrativo separato è `10.99.0.0/24` (`wg-admin` `.1`, laptop `.2`);
`10.10.10.0/24` resta riservato al futuro overlay applicativo.

Totale allocato: 8 vCPU, 10 GiB RAM, 180 GiB thin. L'host deve avere ulteriore
margine per Workstation e il sistema operativo.

VPS14 usa inizialmente un virtual disk thin da 40 GiB; il disco può essere
espanso in seguito. Monitorare soprattutto Wazuh Indexer, Docker, i database e
Nextcloud, che sono i principali consumatori di storage.

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
- **Prerequisiti:** VMware Workstation Pro, ISO leggibili, almeno 180 GiB
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
- **Comandi Linux disponibili:** `bootstrap.sh --check/--apply --checkpoint 1`
  per root/LVM; `--checkpoint 2` per rete a due NIC con rollback e
  riconnessione `.145 -> .14`; `--checkpoint 3` per WireGuard admin e staging
  del primo client. L'espansione futura del disco VMware richiederà una fase
  separata `growpart`/`pvresize`.
- **Comandi Windows:** autoinstall usa i file
  `iac/linux/autoinstall/vps12-user-data.yaml` e
  `iac/linux/autoinstall/vps14-user-data.yaml`; il dry-run Windows reale è
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File iac/windows/bootstrap.ps1 -Check`.
- **Runner da DC02:** `iac/windows/setup-powerseven.ps1 -Check
  -Vps14Address <DHCP_IP> -UbuntuUsername <UBUNTU_USER> -Checkpoint N` esegue
  un check remoto read-only; `-PrepareBootstrap` migra soltanto
  bootstrap/wrapper/sudoers; `-Apply` applica il checkpoint Linux. La password
  SSH e la prima autenticazione sudo restano prompt interattivi nativi e non
  vengono salvate. Per CP2 il runner riconnette a `192.168.214.14`; per CP3
  configura route persistente DC02, firewall RDP e recupera il client config
  fuori repository.
- **Prerequisiti:** PHASE 2 PASS; placeholder risolti in workspace locale;
  password e chiavi fuori Git.
- **Risultato atteso:** Ubuntu Desktop/Server e Windows Server 2022 Desktop
  Experience installati con hostname, SSH/OpenSSH iniziali e bootstrap Linux
  installato.
- **Stato:** **PARTIAL**. Credential bootstrap DC02→VPS14, SSH key persistence,
  rerun passwordless, wrapper NOPASSWD ristretto, migrazione/rollback del
  bootstrap e Checkpoint 1 storage sono **LIVE VALIDATED**; CP2 networking,
  CP3 VPN e la UX remota `-Check`/`-PrepareBootstrap` sono implementati ma
  **NOT YET LIVE VALIDATED**. Il bootstrap Windows VPS13 è **LIVE VALIDATED**.

  Il primo check remoto CP2 ha confermato key-only e il rilevamento del
  bootstrap live CP1-only; si è fermato esclusivamente per un errore di
  `ValidateSet` sullo status `MISSING`, corretto nella milestone corrente.
  Il terminale è sembrato attendere un input dopo il terzo PASS: comportamento
  da verificare domani solo se si ripresenta; non è stata introdotta alcuna
  modifica speculativa.

### PHASE 4 — rete/IP underlay

- **Modalità:** manuale/partially automatizzabile.
- **Comandi previsti:** `sudo powerseven-bootstrap --check/--apply
  --checkpoint 2`; il runner esegue la transizione DHCP→`.14`, conferma il
  rollback guard dopo la riconnessione e valida route/DNS/default gateway.
- **Prerequisiti:** OS installato; VMnet8/gateway validati.
- **Risultato atteso:** VMnet8 `.12/.13/.14` statici, gateway `.2`, DNS DC02
  `.13`; NIC Bridged DHCP senza default route/DNS e senza collisione subnet.
- **Stato:** **IMPLEMENTED / NOT YET LIVE VALIDATED** per CP2 Linux; la rete
  VPS13 Windows è **LIVE VALIDATED** con interfaccia reale.

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
- **Stato:** **LIVE VALIDATED / READY**. `bootstrap.ps1` rileva lo stato,
  installa AD DS/DNS, promuove una nuova forest senza seconda promozione,
  configura DNS, utenti/gruppi e record in modo idempotente. Il test live di
  `validate-vps13.ps1` ha restituito `PASS=28 WARN=0 FAIL=0`.

  Sono stati validati live hostname `DC02`, `192.168.214.13/24`, gateway
  `192.168.214.2`, DNS client `192.168.214.13`, forwarder `1.1.1.1`/
  `8.8.8.8`, dominio `LAB.TEST`, AD DS, DNS, zone `lab.test` e `_msdcs`,
  gruppi PowerSeven, provisioning utenti interattivo, record DNS e idempotenza
  dei checkpoint principali. Ansible Windows resta un workflow separato e non è
  dichiarato completo.

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

- **Modalità:** runner controllato da DC02; nessun WireGuard su Jarvis/Fedora.
- **Comandi previsti:** `sudo powerseven-bootstrap --check/--apply
  --checkpoint 3`, con route DC02 persistente e test RDP `10.99.0.2 ->
  192.168.214.13:3389`.
- **Prerequisiti:** CP2 confermato, seconda NIC Bridged configurata in VMware,
  LAN fisica non sovrapposta, secret/key bootstrap già validati.
- **Risultato atteso:** `wg-admin` `.1`, client `.2`, UDP/51820 soltanto sulla
  Bridged, nessun NAT normale, config client in `C:\ProgramData\PowerSeven\clients`.
- **Stato:** **IMPLEMENTED / NOT YET LIVE VALIDATED** per VPN admin;
  peer VPS12/VPS13, CA, DNS applicativo e overlay `10.10.10.0/24` restano
  fasi successive.

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
| `iac/linux/` | A parziale + B/C | `bootstrap.sh` implementa il checkpoint storage LVM read-only/apply; autoinstall e variables restano template con placeholder. Rete, pacchetti e servizi non sono ancora implementati. |
| `iac/windows/` | A + B | `bootstrap.ps1` implementa checkpoint 1-8 ed è stato validato live su VPS13; `validate-vps13.ps1` è read-only; `autounattend.xml` resta input installer. Ansible Windows non è completo. |
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
| Ubuntu bootstrap | checkpoint storage LVM eseguibile + autoinstall template | rete, pacchetti, WireGuard e servizi VPS14 | estendere `bootstrap.sh` a checkpoint separati e testarli su VPS14 |
| Windows provisioning | workflow PowerShell checkpoint 1-8 live validato | integrazione Ansible e firewall policy completa | wrapper Ansible e policy firewall |
| Ansible | inventory/playbook/contratti | task per tutti i role eccetto tuning Wazuh | implementare un role per checkpoint |
| Docker Compose | servizi dichiarati, `restart: no` | tag approvati, `.env`, cron Nextcloud, config/volumi live | chiudere immagini e deployment per app |
| CA/TLS | riferimenti e contratti | generazione CA/certificati e trust | generatore locale escluso da Git |
| AD users/groups | gruppi automatici + utenti interattivi al checkpoint 6 live validati | manifest locale non ancora orchestrato | mantenere password interattive; aggiungere manifest locale in seguito |
| DNS records | `iac/windows/provisioning.psd1` + checkpoint 5/7 live validati | forwarder finale AdGuard resta successivo | riconciliare il forwarder finale quando AdGuard sarà disponibile |
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
