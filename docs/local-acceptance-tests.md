# Test di accettazione locale

Equivalenza significa infrastruttura e funzionamento, non stato applicativo.
Database, volumi, repository, file Nextcloud e storico Wazuh devono essere
vuoti. Ogni test registra host, timestamp, comando, risultato e log sintetico.

## Prerequisiti

- tre VM accese su VMnet8;
- IP underlay `.12/.13/.14` assegnati;
- overlay WireGuard configurato;
- secret refs risolti fuori repository;
- client WireGuard di test separato dal client host già esistente.

## Suite

| ID | Test | Verifica | Successo |
|---|---|---|---|
| NET-01 | Underlay | ping e TCP tra `192.168.214.12`, `.13`, `.14` | tre VM comunicano |
| NET-02 | Internet NAT | query DNS/HTTPS via `192.168.214.2` | uscita controllata |
| WG-01 | Hub | VPS14 ascolta UDP 51820 | listener corretto |
| WG-02 | Peer VM | handshake VPS12/VPS13 con VPS14 | `.12/.13/.14` raggiungibili |
| WG-03 | CUTOVER TEST | client `10.10.10.101` viene spostato al nuovo hub solo a fine rebuild | peer autorizzato funziona; non eseguire durante il bootstrap |
| DNS-00 | Piani indirizzo | VPS12/VPS14 usano DC02 `192.168.214.13`; DC02 usa AdGuard `192.168.214.14` | DNS infrastrutturale su underlay |
| DNS-01 | Zone | DC02 risolve `lab.test`, `_msdcs.lab.test` | zone presenti |
| DNS-02 | Record | `dc02` → `192.168.214.13`; app `cloud`, `git`, `pdf`, `login`, `panel`, `wazuh`, `wings`, `adguard`, `scribble*` → `10.10.10.14` | piani indirizzo corretti |
| DNS-03 | Forwarder | DC02 inoltra query esterne ad AdGuard | query Internet funziona |
| ID-01 | AD | dominio `LAB.TEST`, utenti e gruppi | directory nuova disponibile |
| ID-02 | Kerberos | ticket con account test | `kinit`/`klist` validi |
| ID-03 | LDAP | bind LDAP e LDAPS | autenticazione valida |
| ID-04 | Join | VPS12 domain join | `realm list` corretto |
| DESK-01 | XRDP | login AD su VPS12 | sessione XFCE aperta |
| DESK-02 | SSH | SSH secondo policy | accesso solo percorso previsto |
| WIN-01 | RDP | RDP su DC02 secondo policy | sessione ammessa |
| WEB-01 | TLS | Nginx serve `*.lab.test` | SAN/trust/status corretti |
| DB-01 | PostgreSQL | processo, listener, DB vuoti | connessione valida |
| DB-02 | MariaDB | processo, listener, `panel` vuoto | connessione valida |
| DB-03 | Redis | processo/cache | ping Redis valido |
| APP-01 | Docker | reti, container, health | servizi attivi |
| APP-02 | Nextcloud | installazione nuova, LDAP/DB | pagina e login test |
| APP-03 | Forgejo | installazione nuova, LDAP/DB | pagina e login test |
| APP-04 | Stirling | endpoint PDF | risposta attesa |
| APP-05 | AdGuard | DNS/UI | resolver attivo |
| APP-06 | Portal/Scribble | endpoint e processi | risposta attesa |
| PTERO-01 | Panel | Panel e MariaDB | login/health |
| PTERO-02 | Workers | Wings e `pteroq` | daemon/queue healthy |
| WAZUH-01 | Manager | Manager/Indexer/Dashboard | stack attivo |
| WAZUH-02 | Agents | VPS12 e DC02 | due agenti online |
| FW-01 | Firewall | porte da underlay/overlay/Internet | solo superfici previste |
| E2E-01 | End-to-end | client WG → DNS → Nginx → app → identity/DB | flusso completo PASS |

## Cutover WireGuard

WG-03 è l'ultimo test: prima verificare solo handshake e traffico tra VPS12,
VPS13 e VPS14. Il client host `.101` non deve essere collegato al nuovo hub in
parallelo al tunnel Azure. Il cutover richiede sostituire il profilo del client
host in una finestra controllata; questa procedura non viene eseguita da
questa repository.

## Comandi indicativi

Usare account e secret interattivi; non inserire valori reali nei comandi.

```text
ping 192.168.214.13
ping 10.10.10.14
dig @192.168.214.13 cloud.lab.test
dig @192.168.214.13 example.org
curl --resolve cloud.lab.test:443:10.10.10.14 https://cloud.lab.test/
sudo wg show
systemctl is-active nginx docker postgresql mariadb redis-server
sudo docker ps
Get-ADDomain
Get-DnsServerForwarder
realm list
klist
```

## Criterio finale

PASS solo se NET, WG, DNS, identity, accesso, DB, Docker, applicazioni,
Pterodactyl, Wazuh, firewall ed E2E sono PASS. Un servizio avviato ma non
raggiungibile attraverso il percorso previsto è FAIL.

## Non-testato in questo scope

Backup, restore, snapshot, migrazione DB, migrazione Nextcloud/Forgejo,
restore AD, storico Wazuh e recupero dati Azure non fanno parte dell'accettazione.
