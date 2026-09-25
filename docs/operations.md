# Operazioni read-only

Collegare prima un client WireGuard autorizzato e verificare `ping 10.10.10.14`. RDP: `10.10.10.12:3389` (XRDP) oppure `10.10.10.13:3389` (Windows). SSH: `ssh desktopadmin@10.10.10.12`, `ssh Administrator@10.10.10.13`, `ssh serveradmin@10.10.10.14`. Inserire credenziali soltanto nel client interattivo, mai in comandi, output o file.

| Obiettivo | Comando read-only | Segnale atteso | Se fallisce |
|---|---|---|---|
| Tunnel | `sudo wg show` su VPS14 | peer/handshake e interfaccia `wg-final` | controllare client, routing e UDP 51820 |
| VPS12 | `systemctl status xrdp xrdp-sesman wazuh-agent` | servizi attivi | controllare VPN, XRDP e AD |
| DC02 | `Get-ADDomain`; `Get-DnsServerZone`; `Get-Service WazuhSvc` | dominio, zone, agente attivi | isolare AD/DNS/agente |
| Proxy/app | `systemctl status nginx azienda-portal wings pteroq`; `sudo docker ps` | processi/container attivi | controllare backend indicato in [servizi](services.md) |
| Dati | `sudo -u postgres psql -c '\\l'`; `systemctl status mariadb redis-server` | motori attivi | non riavviare: raccogliere log/stato |
| Wazuh | `systemctl status wazuh-manager wazuh-dashboard wazuh-indexer` | stack attivo | distinguere Manager, Indexer e UI |

Controlli trasversali: `ip route`, `resolvectl status`, `ss -tulpn`, `systemctl --failed`, `curl -kI https://wazuh.lab.test` dalla VPN. Non riavviare, reinstallare, cambiare configurazioni o aprire firewall durante una verifica. Annotare host, ora, comando e risultato prima di un'escalation.
