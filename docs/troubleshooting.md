# Troubleshooting

1. VPN assente: controllare il client e `sudo wg show` su VPS14; verificare handshake e UDP 51820.
2. DNS/AD: da VPS12 controllare `resolvectl status`, poi `realm list`; da DC02 `Get-DnsServerZone` e `Get-ADDomain`.
3. XRDP non raggiungibile: controllare la VPN, poi `systemctl status xrdp xrdp-sesman` e `ss -tulpn | grep 3389` su VPS12.
4. Web non disponibile: verificare `systemctl status nginx`, `sudo docker ps` e il backend loopback indicato in `docs/services.md`.
5. Wazuh: controllare servizi su VPS14 e `systemctl status wazuh-agent` su VPS12; su DC02 controllare `Get-Service WazuhSvc`.

Annotare output, ora e host prima di proporre una modifica. Le anomalie di firewall devono essere valutate separatamente.
