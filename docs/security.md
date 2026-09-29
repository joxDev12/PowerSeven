# Sicurezza

## Confini di rete

| Confine | Uso documentato | Cosa non implica |
|---|---|---|
| Internet pubblico | il solo ingresso pubblico dichiarato per la VPN è WireGuard VPS14 UDP 51820; Nginx può essere pubblicato secondo NSG/routing | un listener host non prova che sia Internet-esposto |
| Azure VNet private | tre VNet isolate, ciascuna `172.16.0.0/16` con subnet `172.16.0.0/24` e IP `172.16.0.4` | indirizzo ripetuto legittimo: VNet distinte, nessun peering |
| WireGuard Azure storico | `10.10.10.0/24`, peer e servizi osservati | riferimento storico; non è il VPN admin del rebuild |
| WireGuard admin locale | `10.99.0.0/24`, solo accesso amministrativo | peer autorizzato; ingresso Bridged solo UDP/51820 |
| localhost | `127.0.0.0/8`, backend come Nginx→container/processi | non è raggiungibile direttamente dalla rete senza proxy/forwarding locale |
| Docker | reti bridge dedicate su VPS14 | un container non è automaticamente raggiungibile dalla VNet o da Internet; dipende dai port mapping |

L'Azure NSG filtra il traffico a livello Azure prima che raggiunga l'host; firewall host (Windows Firewall, nftables/UFW/Docker) decide poi sul traffico arrivato. Perciò un binding su una VNet Azure o su `10.10.10.14` non è automaticamente pubblico su Internet. Le tre VNet erano isolate e senza peering. Le regole NSG effettive, i public IP/NAT e la loro associazione non sono stati verificati direttamente in questa revisione. Non risultano configurazioni WireGuard temporanee attive; UDP 51820 è la porta VPN operativa dichiarata.

Nel target locale la NIC Bridged di VPS14 non deve esporre SSH, Cockpit, RDP,
PostgreSQL, Docker, Nginx o applicazioni. Il firewall nftables del checkpoint 3
consente su quella NIC solo UDP/51820 e traffico correlato; il RDP su DC02 è
limitato da Windows Firewall alla subnet `10.99.0.0/24`.

## Controlli osservati e superfici

TLS usa certificati emessi da `SOC Lab Training CA` per `lab.test`; sono stati consultati solo subject, issuer e date. Chiavi private e materiale CA non sono stati copiati. Wazuh agent è attivo su VPS12 e DC02, con Manager VPS14. I firewall profili Windows risultavano attivi. Su VPS12 e VPS14 UFW risultava inattivo; VPS14 usa nftables/Docker per forwarding e NAT. Verifiche read-only: `sudo ss -tulpn`, `sudo nft list ruleset`, `Get-NetFirewallProfile`, `Get-NetTCPConnection -State Listen`.

Le osservazioni Azure storiche includevano PostgreSQL su `10.10.10.14`; nel
target locale CP5 i database host si legano a `127.0.0.1` e
`192.168.214.14`. L'ingresso Bridged continua a essere bloccato da CP3, mentre
l'autenticazione DB resta locale finché non saranno definiti ruoli e policy
applicative. Riesaminare separatamente gli NSG Azure, RDP/SSH/WinRM su DC02,
Nginx, Wings SFTP 2022, Wazuh e i binding Scribble. Nessuna porta in ascolto è
classificata automaticamente come Internet-pubblica.
