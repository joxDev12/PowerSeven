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

## Target locale approvato

VPS14 ha due NIC: VMnet8 statico `192.168.214.14/24`, gateway unico
`192.168.214.2`, DNS `192.168.214.13`; e una NIC Bridged DHCP senza default
route e senza DNS. Il VPN amministrativo separato usa `wg-admin`
`10.99.0.0/24` (`10.99.0.1` VPS14, `10.99.0.2` Jarvis,
`10.99.0.3` giorgio-laptop) e raggiunge VMnet8.
DC02 mantiene la route persistente `10.99.0.0/24 via 192.168.214.14`.

I bridge Docker di VPS14 includono `172.18.0.0/16`, `172.19.0.0/16`,
`172.20.0.0/16`, `172.31.90.0/24` e `172.31.91.0/24`.

Vedere [rete WireGuard](../diagrams/wireguard-network.html).
