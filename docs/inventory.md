# Inventario

| Host | OS / capacità | Servizi e porte | Dipendenze | Amministrazione |
|---|---|---|---|---|
| soc-desktop | Ubuntu 24.04.4, 4 vCPU, 15 GiB RAM, 128 GB | SSH 22, XRDP 3389, WG, Wazuh | DC02 DNS/AD; VPS14 Wazuh/WG | SSH, RDP, sudo read-only |
| DC02 | Windows Server 2022, 2 vCPU, 4 GiB RAM, 126 GB C: | AD/DNS/Kerberos/LDAP, SSH 22, RDP 3389, WG, Wazuh | VPS14 DNS forwarder/WG/Wazuh | SSH, RDP, PowerShell Administrator |
| soc-server | Ubuntu 24.04.4, 4 vCPU, 15 GiB RAM, 128 GB | WG 51820, SSH 22, HTTP/S 80/443, Wazuh, DB, Docker, Wings | DNS DC02 per `lab.test`; hub per VPN | SSH, sudo read-only |

Storage libero rilevato: VPS12 ~115 GB, VPS13 ~112 GB, VPS14 ~96 GB. Per servizi, porte e dipendenze applicative consultare [services](services.md), [databases](databases.md) e [docker](docker.md).
