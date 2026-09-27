# Remote administration VPN locale

Questo è il piano locale PowerSeven. Jarvis/Fedora non installa né orchestra
WireGuard.

## Topologia

`laptop 10.99.0.2/32 -> wg-admin 10.99.0.1/24 su VPS14 ->
192.168.214.0/24`. Il VPN usa la NIC Bridged di VPS14 solo per UDP/51820;
VMnet8 resta la rete di management con l'unica default route via
`192.168.214.2` e DNS `192.168.214.13`.

Il client usa `AllowedIPs = 192.168.214.0/24,10.10.10.0/24`. DC02 riceve la
route persistente `10.99.0.0/24 via 192.168.214.14`; il masquerade non è la
configurazione normale. La route equivalente per VPS12 arriva più avanti.

## VMware: operazioni manuali prima del live test

1. Spegnere VPS14.
2. Conservare la NIC 1 su VMnet8 e aggiungere la NIC 2 su Bridged.
3. Abilitare “Connected” e “Connect at power on”; scegliere la scheda fisica
   Wi-Fi/Ethernet reale, non una rete virtuale.
4. Non modificare MAC/order della NIC VMnet8. Annotare il MAC della Bridged e,
   se possibile, assegnarle una DHCP reservation sulla LAN fisica.
5. Verificare che la LAN fisica non usi `192.168.214.0/24` e che il Wi-Fi non
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

CP3 installa `wg-admin`, chiavi server persistenti, forwarding IPv4 e una
tabella nftables dedicata. Dalla Bridged è permesso solo UDP/51820 e traffico
di ritorno; SSH, Cockpit, PostgreSQL, Docker, Nginx, RDP e applicazioni non
vengono aperti direttamente sulla LAN fisica.

Il runner crea/verifica su DC02 la route verso `10.99.0.0/24`, limita le regole
RDP inbound di DC02 alla subnet `10.99.0.0/24` e salva senza password:

```text
C:\ProgramData\PowerSeven\clients\powerseven-admin-laptop.conf
C:\ProgramData\PowerSeven\clients\PowerSeven-DC02.rdp
```

La private key del client non viene stampata o versionata. VPS14 conserva solo
la public key del peer; dopo SCP il runner chiede al bootstrap di eliminare la
configurazione staged e la private key temporanea. Se il peer esiste ma il
config locale è perso, il rerun fallisce senza rigenerare identità: serve una
rotazione esplicita.

## Test di accettazione

Da laptop importare il `.conf`, connettere WireGuard e verificare:

```text
ping 10.99.0.1
ping 192.168.214.13
RDP 192.168.214.13:3389
```

Verificare inoltre che SSH/servizi VPS14 non siano raggiungibili dall'IP LAN
bridged e che la default route VPS14 resti unica via `192.168.214.2`.
