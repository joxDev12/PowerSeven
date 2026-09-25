# Troubleshooting

Seguire il flusso dall'esterno al componente e usare solo comandi read-only. Annotare host, ora, comando e risultato; non correggere configurazioni durante la diagnosi.

| Sintomo | Catena da verificare | Comandi read-only | Failure mode probabile |
|---|---|---|---|
| VPN assente | client → UDP 51820 → `wg-final` VPS14 | `sudo wg show` | peer/route/NSG o firewall host; la configurazione NSG non è verificata qui |
| DNS o login AD | VPS12 → DC02 → AdGuard → Internet | `resolvectl status`, `realm list`, `Get-DnsServerZone`, `Get-ADDomain`, `Get-DnsServerForwarder` | resolver, AD DS o forwarder |
| XRDP non raggiungibile | VPN → VPS12:3389 → sessione/SSSD | `systemctl status xrdp xrdp-sesman`; `ss -tulpn` | tunnel, listener, desktop manager o AD |
| RDP/SSH DC02 | VPN → DC02 porta richiesta | `Get-NetTCPConnection -State Listen` | servizio Windows o firewall profilo |
| Web non disponibile | VPN/HTTPS → Nginx → backend → DB | `systemctl status nginx`; `sudo docker ps`; comando del backend in [servizi](services.md) | proxy, processo/container o database |
| Pterodactyl | Nginx → panel/worker/Wings → MariaDB | `systemctl status pteroq wings mariadb` | worker, Wings o MariaDB |
| Wazuh | agenti → Manager → Indexer → Dashboard | `systemctl status wazuh-manager wazuh-indexer wazuh-dashboard wazuh-agent`; `Get-Service WazuhSvc` | agente, Manager, indice o UI |

Le anomalie firewall richiedono di distinguere routing VPN, Azure NSG e firewall host; una porta in ascolto sulla VNet non dimostra esposizione Internet. Non è verificata una procedura automatizzata di raccolta log o rollback.
