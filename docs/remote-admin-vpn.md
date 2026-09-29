# Remote administration VPN locale

Questo è il piano locale PowerSeven. Il setup è orchestrato da DC02/VPS14;
Jarvis usa solo il proprio tunnel client.

## Topologia

`client 10.99.0.2/32` e successivi -> `wg-admin 10.99.0.1/24` ->
`192.168.214.0/24`. La VPN usa la NIC Bridged di VPS14 solo per UDP/51820;
VMnet8 resta la rete di management con l'unica default route via
`192.168.214.2` e DNS `192.168.214.13`.

Ogni client usa `AllowedIPs = 192.168.214.0/24`; Internet resta sulla connessione ordinaria. DC02 riceve la
route persistente `10.99.0.0/24 via 192.168.214.14`; il masquerade non è la
configurazione normale. La route equivalente per VPS12 arriva più avanti.

## VMware e LAN fisica: prerequisiti CP3

1. Confermare la configurazione VMware già validata in CP2: NIC 1 su VMnet8,
   NIC 2 Bridged sulla scheda fisica, “Connected” e “Connect at power on”.
2. Non modificare MAC/order della NIC VMnet8. La Bridged usa DHCP normale:
   il runner legge il suo IP corrente e aggiorna `Endpoint` nei profili
   durante ogni Apply CP3, senza rigenerare le chiavi. Se il lease cambia dopo
   che i profili sono stati importati, rieseguire Apply e ridistribuire i
   profili aggiornati ai rispettivi computer.
3. Verificare che la LAN fisica non usi `192.168.214.0/24` e che il Wi-Fi non
   abbia client isolation tra laptop e VM.

Nessun port-forward è necessario per il test dalla stessa LAN. Un eventuale
accesso da Internet richiederà in futuro una sola regola UDP/51820 sul router
fisico, mai su Jarvis.

## Checkpoint

CP2 eseguito dal runner su DC02 configura Netplan per MAC: VMnet8 statico
`.14/24`, gateway `.2`, DNS `.13`; Bridged DHCP con `use-routes: false` e
`use-dns: false`. I file Netplan precedenti vengono salvati e un timer
ripristina automaticamente la configurazione se il runner non conferma dopo
la riconnessione a `.14`.
La conferma attende fino a 45 s che DHCP Bridged, DNS, route, networkd e
Netplan persistente siano pronti: SSH su `.14` non basta per il commit.
CP2 verifica i `.network` generati per i MAC delle due NIC, ricarica e
riconfigura systemd-networkd e prova un singolo restart protetto se restano
unmanaged. Anche il rollback riapplica Netplan e ricarica networkd.

CP3 installa `wg-admin`, chiavi server persistenti, forwarding IPv4 e una
tabella nftables dedicata. Dalla Bridged è permesso solo UDP/51820 e traffico
di ritorno; SSH, Cockpit, PostgreSQL, Docker, Nginx, RDP e applicazioni non
vengono aperti direttamente sulla LAN fisica.
Il firewall viene caricato prima dell'avvio di WireGuard, con dipendenza
systemd anche ai reboot. `-Check -Checkpoint 3` verifica le regole nftables
effettive, oltre alla configurazione persistente. Il runner completa VPN,
export e pulizia dei profili prima di modificare route e filtro RDP su DC02.

Al primo Apply su una nuova installazione il runner chiede quanti dispositivi
creare e un nome per ciascuno. Per automazione accetta
`-PeerNames desktop,portatile,surface` e non chiede input. Sono ammessi nomi
univoci di 1-32 caratteri, iniziati da una lettera e composti da lettere,
numeri, `_` o `-`; vengono salvati in minuscolo. VPS14 conserva i nomi in
`/var/lib/powerseven/admin-vpn/peers` e assegna `.2`, `.3`, ... nell'ordine
scelto. Nei normali rerun il runner legge l'inventario e non chiede nulla.

Lo stato LIVE precedente viene migrato automaticamente: i file public key
e `wg-admin.conf` associano `jarvis` a `.2` e `giorgio-laptop` a `.3`.
I profili già esportati su DC02 vengono riutilizzati senza ruotare le chiavi.

Il runner crea/verifica su DC02 la route verso `10.99.0.0/24`, installa prima
regole RDP distinte per bloccare TCP/3389 da fuori VPN su IPv4 e IPv6, poi
consente `10.99.0.0/24` verso `192.168.214.13`. Gli intervalli escludono gli
indirizzi speciali rifiutati da Windows Defender Firewall. Le regole esistenti
non vengono modificate; i blocchi espliciti prevalgono su eventuali allow più
ampi.
I profili vengono salvati senza password in:

```text
C:\ProgramData\PowerSeven\clients\powerseven-admin-{nome}.conf
C:\ProgramData\PowerSeven\clients\PowerSeven-DC02.rdp
```

Le private key distinte non vengono stampate o versionate. VPS14 conserva solo
le public key dopo l'export; dopo ogni SCP validato il runner elimina lo
staging del peer.
Se un peer esiste ma il config locale è perso, il rerun fallisce senza
rigenerare identità: serve una
rotazione esplicita.
Conservare i profili protetti su DC02 e copiare ciascuno solo sul proprio
computer. Un rerun riusa le identità; se si interrompe prima della pulizia,
lo staging residuo permette di recuperare il profilo mancante.

## Ripresa del test LIVE

1. Confermare che VPS14 resta raggiungibile su VMnet8 `.14` e che la Bridged
   ha un lease DHCP. Non è richiesta alcuna configurazione del router. CP2 è
   già stato validato LIVE dopo reboot; il runner v13 migrerà il bootstrap
   Linux durante l'Apply CP3.
2. Su DC02, PowerShell Administrator: `setup-powerseven.ps1 -Apply -Checkpoint 3`
   con `-Vps14Address 192.168.214.14` e lo stesso `-UbuntuUsername` del CP2.
   Il runner v13 ricostruisce l'inventario dai peer LIVE, riusa i due profili
   locali e configura le nuove regole RDP. Non passare `-PeerNames` durante
   questa migrazione. Se fallisce, ispezionare
   l'errore e rieseguire lo stesso Apply dopo la
   correzione; non cancellare profili, public key o staging per tentare il rerun.
3. Eseguire `setup-powerseven.ps1 -Check -Checkpoint 3`. Su VPS14 verificare
   `systemctl is-active powerseven-admin-firewall wg-quick@wg-admin`,
   `nft list table inet powerseven_admin` e `wg show wg-admin`, senza esporre
   private key. Su DC02 confermare route attiva e persistente e che le regole
   RDP gestite blocchino le sorgenti fuori `10.99.0.0/24` e consentano
   la VPN.
4. Copiare il profilo `jarvis` su Jarvis e `giorgio-laptop` sul portatile in
   modo protetto. Importare ogni profilo sul computer corrispondente; i due
   computer hanno chiavi private distinte. Nessun profilo è destinato a Codex.

Da Jarvis e poi dal laptop, con il rispettivo tunnel attivo, verificare:

```text
ping 192.168.214.14
ping 192.168.214.13
RDP 192.168.214.13:3389
```

Verificare inoltre che SSH/servizi VPS14 non siano raggiungibili dall'IP LAN
bridged, che la default route VPS14 resti unica via `192.168.214.2` e che
Internet dei due client continui a usare la propria connessione normale.
Codex usa la VPN del computer corrente e non gestisce tunnel o chiavi.
L'automation-user su DC02 non viene creato in questa fase.
