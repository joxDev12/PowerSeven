# Windows VPS13/DC02

Target: Windows Server 2022 Datacenter Desktop Experience, `DC02`,
`192.168.214.13/24`, dominio nuovo `LAB.TEST`.

## Workflow eseguibile

`bootstrap.ps1` è un orchestratore a checkpoint, non un installer one-shot.
Le modalità sono mutuamente esclusive: `-Check` esegue un controllo remoto
read-only, `-PrepareBootstrap` migra solo l'infrastruttura bootstrap e `-Apply`
applica il checkpoint richiesto.
Non esegue reboot automaticamente.

```powershell
.\bootstrap.ps1 -Check
.\bootstrap.ps1 -Apply -Checkpoint 1
.\bootstrap.ps1 -Apply -Checkpoint 2 -InterfaceAlias Ethernet
# riavvio manuale dopo il cambio hostname; rieseguire checkpoint 2
.\bootstrap.ps1 -Apply -Checkpoint 3
# se restituisce REBOOT_REQUIRED: riavvio manuale, rieseguire checkpoint 3
.\bootstrap.ps1 -Apply -Checkpoint 4
# riavvio manuale dopo la promozione forest
.\bootstrap.ps1 -Apply -Checkpoint 5
.\bootstrap.ps1 -Apply -Checkpoint 6
.\bootstrap.ps1 -Apply -Checkpoint 7
.\validate-vps13.ps1
```

Checkpoint:

1. verifica OS/Desktop Experience e abilita OpenSSH/PowerShell Remoting;
2. hostname, IP, gateway e DNS bootstrap;
3. feature AD DS e DNS;
4. forest/domain `LAB.TEST` con prompt SecureString DSRM;
5. zona AD-integrated, `_msdcs`, forwarder iniziale `1.1.1.1`/`8.8.8.8` e
   DNS client post-promozione `192.168.214.13`;
6. gruppi automatici e utenti definiti dall'installatore, senza password versionate;
7. record A `lab.test` dal catalogo locale;
8. validation read-only.

`validate-vps13.ps1` verifica hostname, rete, servizi AD DS/DNS, forest/domain,
zone, record, utenti, gruppi e membership. Non verifica né stampa password.

## Runner VPS14 da DC02

`setup-powerseven.ps1` prepara l'accesso iniziale a VPS14 senza memorizzare
password. In questa fase l'indirizzo DHCP viene fornito con `-Vps14Address`;
la discovery automatica DHCP resta un'estensione successiva.

```powershell
.\setup-powerseven.ps1 -Check -Vps14Address 192.168.214.145 -UbuntuUsername serveradmin -Checkpoint 2
.\setup-powerseven.ps1 -PrepareBootstrap -Vps14Address 192.168.214.145 -UbuntuUsername serveradmin -Checkpoint 2
.\setup-powerseven.ps1 -Apply -Vps14Address 192.168.214.145 -UbuntuUsername serveradmin -Checkpoint 1
.\setup-powerseven.ps1 -Apply -Vps14Address 192.168.214.145 -UbuntuUsername serveradmin -Checkpoint 2
.\setup-powerseven.ps1 -Apply -Vps14Address 192.168.214.14 -UbuntuUsername serveradmin -Checkpoint 3
```

`-Check` richiede una chiave PowerSeven già presente; combina verifica SSH
key-only, bootstrap contract `--protocol` e capabilities in una sessione, poi
esegue il checkpoint read-only in una seconda sessione. Non fa staging, SCP,
password o mutazioni. Exit code `10` indica remediation necessaria ma
nessun errore tecnico; un exit code diverso da zero indica un errore reale.
`-PrepareBootstrap` usa il flusso transazionale sudo già validato e si ferma
dopo la migrazione, senza eseguire il checkpoint.

In `-Apply` il primo enrollment usa il prompt nativo di `ssh.exe` per la
password Ubuntu e il prompt nativo di `sudo` per una sola autenticazione.
PowerShell non acquisisce, passa in argv, salva o stampa le password. Il
runner crea una chiave ED25519 senza passphrase sotto
`C:\ProgramData\PowerSeven\ssh\`, applica ACL ristrette, installa la public
key in `~/.ssh/authorized_keys` e verifica l'accesso con
`PasswordAuthentication=no`/`IdentitiesOnly=yes`.

Trasferisce poi `iac/linux/bootstrap.sh` in `/usr/local/lib/powerseven/`, crea
il wrapper root-owned `/usr/local/sbin/powerseven-bootstrap` e valida
`/etc/sudoers.d/powerseven-bootstrap` con `visudo`. Il wrapper accetta solo
`--check|--apply --checkpoint N` con checkpoint allowlisted, oltre ai probe
metadata `--version`/`--capabilities`; non consente path, script o shell
arbitrari. La policy sudo è `NOPASSWD` soltanto per quel wrapper.

Dopo la prima esecuzione, riaprire PowerShell non richiede una nuova password:
usare la stessa chiave persistente e, per evitare anche il prompt username,
passare `-UbuntuUsername`. CP2 esegue prima un check remoto read-only: se `.14`
è già conforme termina senza token o nuova transazione; altrimenti configura
VMnet8 statico `.14` e Bridged DHCP senza default route/DNS. Il passaggio `.145`
→ `.14` usa una sessione SSH con timeout bounded, attende il nuovo endpoint e
riusa la host identity della sessione DHCP tramite `HostKeyAlias`; il token di
rete viene confermato automaticamente. Il rollback guard resta attivo fino a
quella conferma. Nel contract v14 la conferma attende fino a 45 s che DHCP Bridged,
networkd, route, DNS e Netplan persistente siano pronti; il runner concede
75 s alla chiamata di conferma.
CP3 configura `wg-admin` su VPS14. Su una nuova installazione chiede numero e
nomi dei dispositivi, oppure accetta `-PeerNames desktop,portatile,surface`
senza prompt. VPS14 conserva l'inventario e assegna gli IP da `10.99.0.2/32`;
un rerun non richiede la lista. Il runner aggiunge su DC02 la route persistente
`10.99.0.0/24 via 192.168.214.14`, installa un blocco RDP fuori VPN prima
dell'allow VPN e salva ogni profilo in
`C:\ProgramData\PowerSeven\clients\`. Le chiavi sono indipendenti;
`AllowedIPs` include solo `192.168.214.0/25, 192.168.214.128/25`, che insieme
coprono `192.168.214.0/24` e vincono sulla route VMnet8 `/24` locale di Jarvis
con le regole standard di longest-prefix match. Internet resta fuori dal tunnel.
A ogni Apply il runner aggiorna sia l'endpoint DHCP sia queste route nei profili
conservati su DC02; dopo l'Apply vanno ridistribuiti e reimportati sui client.
La generazione resta nel bootstrap Linux VPS14; DC02 esporta i file, mentre ciascun computer
importa solo il proprio client WireGuard. Codex usa la VPN del computer corrente.
I file client sono secret locali e non entrano nel repository.
La Bridged usa DHCP normale. A ogni Apply CP3 il runner legge l'IP corrente di
VPS14 e aggiorna `Endpoint` nei profili locali senza cambiare le private key;
se il lease cambia dopo l'import sui client, ridistribuire i profili aggiornati.
Il runner configura prima la VPN ed esporta i profili,
poi aggiunge la route e le tre regole RDP gestite su DC02 (blocco IPv4/IPv6,
allow VPN). `-Check -Checkpoint
3` controlla anche route attiva/persistente, regole RDP e profili distinti.

## Dichiarazioni e secret

- `provisioning.psd1`: target VPS13, `LAB.TEST`, forwarder e record DNS;
- `users.psd1`: gruppi PowerSeven e catalogo utenti vuoto;
- `users.local.psd1`: eventuale manifest locale dell'installatore, ignorato da Git;
- `secrets.example.psd1`: riferimenti runtime, senza valori segreti;
- `secrets.psd1`: file locale ignorato da Git, opzionale; in assenza il
  workflow richiede DSRM e password utenti con `Read-Host -AsSecureString`.

AD CS, LDAPS, CA, WireGuard e gli altri host restano fuori scope.
