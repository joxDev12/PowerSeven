# Rete

| Sistema | Interfacce significative | Route / note |
|---|---|---|
| VPS12 | `eth0` `172.16.0.4/24`, `wg-final` `10.10.10.12/32` | DNS `10.10.10.13`; unica route VPN operativa |
| VPS13 | Ethernet `172.16.0.4/24`, `Lab-Final` `10.10.10.13/32` | DNS locale e forwarder `10.10.10.14` |
| VPS14 | `eth0` `172.16.0.4/24`, `wg-final` `10.10.10.14/24` | hub VPN e bridge Docker multipli |

L'indirizzamento `172.16.0.0/24` è la rete cloud sottostante, non il piano di amministrazione del lab. I bridge Docker di VPS14 includono `172.18.0.0/16`, `172.19.0.0/16`, `172.20.0.0/16`, `172.31.90.0/24` e `172.31.91.0/24`.

Vedere [rete WireGuard](../diagrams/wireguard-network.html).
