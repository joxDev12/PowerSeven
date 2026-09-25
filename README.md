# PowerSeven

Documentazione dell'infrastruttura SOC/Lab rilevata il 25 settembre 2026 con ispezione read-only delle tre VM connesse via WireGuard.

| VM | VPN | Ruolo verificato |
|---|---|---|
| `soc-desktop` | `10.10.10.12` | Ubuntu Desktop, XRDP, membro `lab.test`, Wazuh agent |
| `DC02` | `10.10.10.13` | Windows Server 2022 DC unico, AD DS, DNS, KDC, OpenSSH, Wazuh |
| `soc-server` | `10.10.10.14` | WireGuard hub, Nginx, Wazuh, Docker, DB, Pterodactyl |

La sola VPN operativa è `10.10.10.0/24`; VPS14 è l'hub WireGuard e ascolta su UDP `51820`. Client assegnati: `101` giorgio, `102` peppe, `103` marco, `104` monia, `105` rocca, `106` chiara, `107` simone. I servizi web `*.lab.test` risolvono a VPS14.

Diagrammi: [panoramica](diagrams/architecture-overview.html), [WireGuard](diagrams/wireguard-network.html), [VPS14](diagrams/vps14-services.html), [accesso remoto](diagrams/remote-access-sequence.html), [DNS/AD](diagrams/dns-active-directory.html), [flussi applicativi](diagrams/application-flows.html).

Documentazione: [architettura](docs/architecture.md) · [inventario](docs/inventory.md) · [operazioni](docs/operations.md) · [sicurezza](docs/security.md) · [troubleshooting](docs/troubleshooting.md).

Nessuna credenziale, chiave privata, token o file `.env` è incluso.
