# Architettura

La [mappa end-to-end](../diagrams/powerseven-end-to-end.html) è il punto di ingresso. VPS14 (`10.10.10.14`) è l'hub WireGuard, reverse proxy e host della piattaforma applicativa; VPS12 (`10.10.10.12`) è il desktop SOC con XRDP; VPS13/DC02 (`10.10.10.13`) è il controller di dominio e server DNS unico rilevato.

| Piano | Componenti e dipendenze | Stato osservato |
|---|---|---|
| Accesso | Client `10.10.10.101–107` → `wg-final` VPS14 UDP 51820 → RDP/SSH e HTTPS | WireGuard e raggiungibilità VPN verificati |
| Identità | VPS12 → DC02 per DNS, Kerberos, AD e LDAP; le integrazioni LDAP delle web app sono richieste dalla topologia ma la loro configurazione runtime non è verificata | DC02 AD DS/DNS e join VPS12 verificati |
| Applicazioni | Nginx su VPS14 inoltra HTTPS ai servizi locali/container | listener e backend locali verificati |
| Dati e osservabilità | PostgreSQL, MariaDB e Redis su VPS14; agenti VPS12/DC02 → Wazuh Manager | processi/servizi verificati; mapping completo app→database non verificato salvo quanto indicato in [database](databases.md) |

L'unico overlay operativo è `wg-final` su `10.10.10.0/24`. Non esiste un overlay WireGuard temporaneo attivo. DC02 inoltra le query esterne verso AdGuard su VPS14, che usa upstream Internet. I dettagli dei confini di rete sono in [sicurezza](security.md); i drill-down restano [WireGuard](../diagrams/wireguard-network.html), [DNS/AD](../diagrams/dns-active-directory.html) e [VPS14](../diagrams/vps14-services.html).

## Verifica read-only

Le tre VM rispondevano via SSH. `wg-final`, XRDP, AD DS/DNS, Nginx, Docker, PostgreSQL, Wazuh e Wings risultavano attivi; i backend HTTP locali di VPS14 hanno restituito 200, 302 o 401. Comandi: `sudo wg show` (VPS14), `systemctl status xrdp` (VPS12), `Get-ADDomain` (DC02), `sudo docker ps` e `sudo systemctl status nginx` (VPS14).
