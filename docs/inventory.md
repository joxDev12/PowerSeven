# Inventario target locale PowerSeven

| Host | OS / capacità | Servizi e porte | Dipendenze | Amministrazione |
|---|---|---|---|---|
| soc-desktop | Ubuntu Desktop 24.04.x, 2 vCPU, 2 GiB RAM, 80 GiB thin | SSH 22, XRDP 3389, WG, Wazuh | DC02 DNS/AD; VPS14 Wazuh/WG | SSH, RDP, sudo read-only |
| DC02 | Windows Server 2022 Datacenter Desktop Experience, 2 vCPU, 3 GiB RAM, 60 GiB thin | AD/DNS/Kerberos/LDAP, SSH 22, RDP 3389, WG, Wazuh | VPS14 DNS forwarder/WG/Wazuh | SSH, RDP, PowerShell Administrator |
| soc-server | Ubuntu Server 24.04.x, 4 vCPU, 5 GiB RAM, 120 GiB thin | WG 51820, SSH 22, HTTP/S 80/443, Wazuh, DB, Docker, Wings | DNS DC02 per `lab.test`; hub per VPN | SSH, sudo read-only |

Capacità target complessiva: 8 vCPU, 10 GiB RAM, 260 GiB thin. Per servizi,
porte e dipendenze applicative consultare [services](services.md),
[databases](databases.md) e [docker](docker.md).
