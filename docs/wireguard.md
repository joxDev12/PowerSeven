# WireGuard

| Interfaccia | Host | Rete | Porta | Stato |
|---|---|---|---|---|
| `wg-final` | VPS14 | `10.10.10.0/24` | UDP 51820 | hub attivo |
| `wg-final` | VPS12 | `10.10.10.12/32` | porta dinamica | handshake osservato |
| `Lab-Final` | VPS13 | `10.10.10.13/32` | porta dinamica | handshake osservato |
| client | esterni | `10.10.10.101–107/32` | dinamiche | peer assegnati |

VPS14 inoltra traffico tra peer della stessa rete tramite regola nftables `wg-final`→`wg-final`. Non sono riportati materiali chiave; le configurazioni e le chiavi esistono in `/etc/wireguard` su VPS14 e sono dati sensibili.

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
