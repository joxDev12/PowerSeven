# Linux bootstrap e host configuration

Target: Ubuntu Desktop VPS12 e Ubuntu Server VPS14. `bootstrap.sh` è ora il
workflow Linux eseguibile per checkpoint; i template e le variabili restano
dichiarativi.

## Contratto

- hostname e rete statica underlay sono definiti nei template per VM;
- DNS iniziale è `1.1.1.1`/`8.8.8.8`; il gateway VMware `192.168.214.2` è
  usato solo per il routing;
- SSH è installato come superficie di bootstrap, con chiave esterna;
- aggiornamenti e upgrade pacchetti sono disabilitati nei template;
- `bootstrap.sh --check/--apply --checkpoint 1` rileva root/LVM e, in Apply,
  espande solo il free space già disponibile nel VG;
- il contratto corrente del bootstrap è la versione `14`; ogni modifica
  incompatibile o comportamentale richiede l'incremento esplicito della
  versione, anche quando le capabilities restano `checkpoints=1,2,3`;
- `--protocol` espone versione e capabilities con output deterministico in un
  solo probe read-only per il runner Windows;
- il checkpoint 2 configurerà le due NIC: VMnet8 statico `.14` con gateway
  `.2`/DNS `.13` e NIC bridged DHCP senza default route né DNS;
- il checkpoint 3 configura il solo VPN amministrativo `wg-admin`
  `10.99.0.0/24`; l'overlay applicativo futuro `10.10.10.0/24` resta separato;
- dominio, Docker e applicazioni arrivano dopo il bootstrap via Ansible.

Il bootstrap può essere installato da DC02 dal runner
`iac/windows/setup-powerseven.ps1`: il file Linux viene copiato in un path
root-owned e invocato solo tramite il wrapper allowlisted
`/usr/local/sbin/powerseven-bootstrap`. Nessuna password SSH/sudo è richiesta
dal bootstrap Linux o salvata nel repository.

## Checkpoint 1 — storage

```bash
sudo ./iac/linux/bootstrap.sh --check --checkpoint 1
sudo ./iac/linux/bootstrap.sh --apply --checkpoint 1
```

Il checkpoint deriva root device, filesystem, LV, VG e PV dal sistema reale.
Con free space nel VG usa `lvextend -l +100%FREE -r`; un secondo Apply è
no-op. Un aumento futuro del disco VMware richiederà un checkpoint separato
per partizione/PV (`growpart`/`pvresize`), che questa fase rileva ma non esegue.
Il disco VPS14 iniziale è thin da 40 GiB ed è espandibile; monitorare Wazuh
Indexer, Docker, database e Nextcloud.

## Checkpoint 2 — rete a due NIC

```bash
sudo ./iac/linux/bootstrap.sh --check --checkpoint 2
sudo ./iac/linux/bootstrap.sh --apply --checkpoint 2 --network-token <token>
sudo ./iac/linux/bootstrap.sh --apply --checkpoint 2 --confirm-network <token>
```

Il checkpoint riconosce le interfacce dall'indirizzo/subnet e dal MAC, non da
`ens32`/`ens34`. Salva i file Netplan, applica la configurazione con un timer di
rollback e richiede una conferma dal runner dopo la riconnessione a
`192.168.214.14`. La NIC bridged mantiene il DHCP ma usa
`dhcp4-overrides: use-routes: false` e `use-dns: false`; dopo `netplan apply`
il bootstrap verifica i due file `.network` generati sotto
`/run/systemd/network/` tramite MAC, abilita systemd-networkd, esegue
`networkctl reload` e `reconfigure`; se le NIC restano unmanaged per 3 secondi
effettua un singolo restart protetto e riprova per altri 3 secondi. Poi la
verifica richiede `configured` e il file `.network` Netplan attivo per ogni NIC;
gli stati `configuring`, `unmanaged` e `failed` sono riportati separatamente. La
validazione completa è bounded a 45 secondi prima del rollback. Il rollback
riapplica Netplan e ricarica/reconfigura networkd. Dopo
la conferma il file `/etc/netplan/99-powerseven.yaml` resta persistente,
root-owned, mode `600` e validato con `netplan generate`; un check con runtime
corretto ma sorgente persistente assente richiede remediation. La validazione
definitiva include un reboot controllato e un nuovo `--check --checkpoint 2`.

## Checkpoint 3 — VPN amministrativo

```bash
sudo ./iac/linux/bootstrap.sh --check --checkpoint 3
sudo ./iac/linux/bootstrap.sh --apply --checkpoint 3 --peer-list desktop,portatile,surface
sudo ./iac/linux/bootstrap.sh --peer-status
sudo ./iac/linux/bootstrap.sh --apply --checkpoint 3 --cleanup-client desktop
```

Il checkpoint configura `wg-admin` (`10.99.0.1/24`, UDP/51820), forwarding
IPv4, firewall nftables dedicato e i peer scelti al primo Apply. I nomi sono
salvati in `/var/lib/powerseven/admin-vpn/peers` e ricevono indirizzi da
`10.99.0.2/32` in avanti. Un rerun conserva l'inventario e non rigenera i peer
esistenti. La migrazione v13 ricava nomi e indirizzi dai public key file e da
`wg-admin.conf`, senza cambiare le chiavi. Ogni configurazione client viene
generata solo dopo che il firewall nftables è caricato e verificato; l'unità
WireGuard richiede l'unità firewall anche al boot. Il check confronta le
regole nftables in esecuzione con la policy attesa.
Il profilo viene messo in staging protetto per SCP key-only dal runner Windows;
dopo la
conferma del trasferimento il file e la chiave privata temporanea vengono
rimosse da VPS14. Se il peer esiste ma lo staging è perso, il bootstrap rifiuta
di rigenerare l'identità automaticamente. I client instradano la rete privata
come due route più specifiche, `192.168.214.0/25` e `192.168.214.128/25`, non
Internet. Queste route vincono su una route locale `/24` via longest-prefix
match.
`--admin-endpoint` espone in sola lettura l'IP Bridged corrente e la porta
UDP/51820 al runner, che sincronizza i profili client nei rerun.

Il ritorno `10.99.0.0/24 -> 192.168.214.0/24` usa una route persistente su DC02;
masquerade è solo fallback documentato e non viene configurato dal bootstrap.

Renderizzare i placeholder (`<...>`/`REQUIRED_SECRET`) in un workspace escluso
da Git prima di un futuro provisioning.
