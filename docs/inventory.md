# Inventario target locale PowerSeven

| Host | OS / capacità | Servizi e porte | Dipendenze | Amministrazione |
|---|---|---|---|---|
| soc-desktop | Ubuntu Desktop 24.04.4, 2 vCPU, 2 GiB RAM, 80 GiB | SSH 22, XRDP 3389, WG, Wazuh | DC02 DNS/AD; VPS14 Wazuh/WG | SSH, RDP, sudo read-only |
| DC02 | Windows Server 2022 Datacenter, 2 vCPU, 3 GiB RAM, 80 GiB | AD/DNS/Kerberos/LDAP, SSH 22, RDP 3389, WG, Wazuh | VPS14 DNS forwarder/WG/Wazuh | SSH, RDP, PowerShell Administrator |
| soc-server | Ubuntu Server 24.04.4, 4 vCPU, 6 GiB RAM, 160 GiB | WG 51820, SSH 22, HTTP/S 80/443, Wazuh, DB, Docker, Wings | DNS DC02 per `lab.test`; hub per VPN | SSH, sudo read-only |

Capacità target complessiva: 8 vCPU, 11 GiB RAM, 320 GiB disco. Per servizi,
porte e dipendenze applicative consultare [services](services.md),
[databases](databases.md) e [docker](docker.md).
