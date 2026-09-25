# Rete

| Sistema | Interfacce significative | Route / note |
|---|---|---|
| VPS12 | Azure `vnet-austriaeast-1`, subnet `172.16.0.0/24`, private IP `172.16.0.4`; `wg-final` `10.10.10.12/32` | VNet isolata, nessun peering |
| VPS13 | Azure `vnet-belgiumcentral-2`, subnet `172.16.0.0/24`, private IP `172.16.0.4`; `Lab-Final` `10.10.10.13/32` | VNet isolata, nessun peering |
| VPS14 | Azure `vnet-denmarkeast-1`, subnet `172.16.0.0/24`, private IP `172.16.0.4`; `wg-final` `10.10.10.14/24` | VNet isolata, nessun peering; hub VPN e bridge Docker |

Ogni VNet aveva address space `172.16.0.0/16` e subnet `172.16.0.0/24`.
La ripetizione di `172.16.0.4` non era una collisione perché le VNet erano
distinte e senza peering. Il target locale non replica queste VNet: usa una
sola underlay VMware comune, proposta in `192.168.214.0/24`, più overlay
WireGuard `10.10.10.0/24`.

I bridge Docker di VPS14 includono `172.18.0.0/16`, `172.19.0.0/16`,
`172.20.0.0/16`, `172.31.90.0/24` e `172.31.91.0/24`.

Vedere [rete WireGuard](../diagrams/wireguard-network.html).
