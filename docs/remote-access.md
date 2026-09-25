# Accesso remoto

Il percorso è [documentato nel diagramma](../diagrams/remote-access-sequence.html): client WireGuard → HUB VPS14 → RDP/SSH verso gli indirizzi VPN. RDP è disponibile su VPS12 `10.10.10.12:3389` e DC02 `10.10.10.13:3389`; SSH amministrativo è osservato su 22. La policy di esposizione Internet di RDP/SSH non è verificata e non deve essere dedotta dai listener.

| Destinazione | Processo, protocollo e autenticazione | Dipendenze | Health check read-only | Failure mode |
|---|---|---|---|---|
| VPS12 | XRDP TCP 3389, `security_layer=negotiate`, cifratura alta; `xrdp-sesman` loopback 3350 | `lightdm`, XFCE, Xorg XRDP, SSSD/AD | `systemctl status xrdp xrdp-sesman`; `ss -tulpn` | VPN, XRDP o AD non disponibile |
| VPS12 | SSH TCP 22 | account e policy non verificati | `ss -tulpn` | servizio/rete non disponibile |
| DC02 | RDP TCP 3389, OpenSSH TCP 22, WinRM HTTP 5985 | Windows/AD | `Get-NetTCPConnection -State Listen` | servizio o firewall Windows |

Il join VPS12 è `kerberos-member` su `lab.test`; SSSD ammette `SOC-Desktop-Users@lab.test`. Usare gli IP VPN per l'amministrazione ordinaria; `172.16.0.0/24` è Azure VNet privata e non è il percorso operativo documentato. Non inserire credenziali in comandi, file o repository.
