# WireGuard

| Interfaccia | Host | Rete | Porta | Stato |
|---|---|---|---|---|
| `wg0` | VPS14 Azure corrente | `10.10.10.0/24` | UDP 51820 | hub attivo; unità osservata `wg-quick@wg0.service` |
| `wg-final` | VPS12 | `10.10.10.12/32` | porta dinamica | handshake osservato |
| `Lab-Final` | VPS13 | `10.10.10.13/32` | porta dinamica | handshake osservato |
| client | esterni | `10.10.10.101–107/32` | dinamiche | peer assegnati |

VPS14 inoltra traffico tra peer della stessa rete tramite regola nftables
`wg0`→`wg0`. Il nome dell'interfaccia locale del rebuild resta da verificare;
non assumere `wg0` o `wg-final` prima dell'implementazione. Non sono riportati
materiali chiave; le configurazioni e le chiavi esistono in `/etc/wireguard` su
VPS14 e sono dati sensibili.

| IP | Assegnatario |
|---|---|
| `10.10.10.101` | giorgio |
| `10.10.10.102` | peppe |
| `10.10.10.103` | marco |
| `10.10.10.104` | monia |
| `10.10.10.105` | rocca |
| `10.10.10.106` | chiara |
| `10.10.10.107` | simone |

Non esistono altri overlay WireGuard operativi. La VPN temporanea usata nella migrazione è stata rimossa dalle VM e la relativa porta pubblica è stata rimossa dall'NSG Azure.

## VPN amministrativo del rebuild locale

Il design locale non riutilizza `10.10.10.0/24` per l'amministrazione. Il
checkpoint Linux crea `wg-admin` su VPS14 con `10.99.0.1/24`, UDP/51820 sulla
NIC Bridged e i peer nominati dall'utente al primo Apply CP3. Gli indirizzi
sono assegnati da `10.99.0.2/32` in avanti e conservati nell'inventario
persistente. I peer raggiungono solo
`192.168.214.0/25, 192.168.214.128/25`. Le due route coprono la rete
`192.168.214.0/24` e sono più specifiche della route VMnet8 locale di Jarvis;
Internet non attraversa il tunnel.

Il runner da DC02 aggiunge la route persistente `10.99.0.0/24 via
192.168.214.14`, blocca RDP da fuori VPN e recupera ogni profilo in
`C:\ProgramData\PowerSeven\clients\`. Ogni computer usa il proprio file client;
PowerSeven non orchestra WireGuard su Fedora;
masquerade resta solo fallback, non configurazione normale.
