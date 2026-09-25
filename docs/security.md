# Sicurezza

## Confini di rete

| Confine | Uso documentato | Cosa non implica |
|---|---|---|
| Internet pubblico | il solo ingresso pubblico dichiarato per la VPN è WireGuard VPS14 UDP 51820; Nginx può essere pubblicato secondo NSG/routing | un listener host non prova che sia Internet-esposto |
| Azure VNet privata | `172.16.0.0/24`, ad esempio `172.16.0.4` sulle VM | una porta sulla VNet è privata finché non esistono public IP/NAT/NSG che ne consentano il transito |
| WireGuard | `10.10.10.0/24`, accesso amministrativo e servizi interni | non è Internet pubblico; richiede peer autorizzato e routing del tunnel |
| localhost | `127.0.0.0/8`, backend come Nginx→container/processi | non è raggiungibile direttamente dalla rete senza proxy/forwarding locale |
| Docker | reti bridge dedicate su VPS14 | un container non è automaticamente raggiungibile dalla VNet o da Internet; dipende dai port mapping |

L'Azure NSG filtra il traffico a livello Azure prima che raggiunga l'host; firewall host (Windows Firewall, nftables/UFW/Docker) decide poi sul traffico arrivato. Perciò un binding su Azure VNet o su `10.10.10.14` non è automaticamente pubblico su Internet. Le regole NSG effettive, i public IP/NAT e la loro associazione non sono stati verificati direttamente in questa revisione. Non risultano configurazioni WireGuard temporanee attive; UDP 51820 è la porta VPN operativa dichiarata.

## Controlli osservati e superfici

TLS usa certificati emessi da `SOC Lab Training CA` per `lab.test`; sono stati consultati solo subject, issuer e date. Chiavi private e materiale CA non sono stati copiati. Wazuh agent è attivo su VPS12 e DC02, con Manager VPS14. I firewall profili Windows risultavano attivi. Su VPS12 e VPS14 UFW risultava inattivo; VPS14 usa nftables/Docker per forwarding e NAT. Verifiche read-only: `sudo ss -tulpn`, `sudo nft list ruleset`, `Get-NetFirewallProfile`, `Get-NetTCPConnection -State Listen`.

Rischi da riesaminare con evidenza NSG: RDP/SSH/WinRM su DC02, Nginx, PostgreSQL su `10.10.10.14`, Wings SFTP 2022, Wazuh e i binding Scribble. Non è stata modificata alcuna regola e nessuna porta in ascolto è qui classificata automaticamente come Internet-pubblica.
