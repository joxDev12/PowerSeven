# Operazioni read-only

Collegare prima il client WireGuard autorizzato, quindi verificare `ping 10.10.10.14`. RDP: connettersi a `10.10.10.12:3389` (XRDP) oppure `10.10.10.13:3389` (Windows); inserire le credenziali solo nel client, mai in comandi o file.

SSH: `ssh desktopadmin@10.10.10.12`, `ssh Administrator@10.10.10.13`, `ssh serveradmin@10.10.10.14`. Su Linux usare `sudo -i` solo quando necessario per lettura; su DC02 la sessione Administrator è già amministrativa.

Su VPS14: `sudo wg show`; `sudo docker ps`; `sudo systemctl status nginx`; `sudo -u postgres psql -c '\l'`; `sudo systemctl status wazuh-manager wazuh-dashboard wazuh-indexer`; `sudo systemctl status wings pteroq azienda-portal`. Su DC02 usare PowerShell: `Get-ADDomain`, `Get-DnsServerZone`, `Get-Service WazuhSvc`, `Get-NetTCPConnection -State Listen`.

Controlli essenziali: `ip route`, `resolvectl status`, `ss -tulpn`, `systemctl --failed`, `curl -kI https://wazuh.lab.test` (da VPN). Non riavviare, reinstallare o cambiare configurazioni durante un controllo.
