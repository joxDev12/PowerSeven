# Active Directory

DC02 è Windows Server 2022 Datacenter, host `10.10.10.13`, unico controller rilevato di `LAB.TEST`/`lab.test`. AD DS e DNS sono installati; DC02 detiene tutti i ruoli FSMO e il dominio è in modalità Windows Server 2016. AD è la dipendenza di identità per VPS12 e, secondo la topologia prevista, per LDAP di Nextcloud, Forgejo e portale; la configurazione LDAP delle singole app non è verificata.

| Ruolo | Porta/protocollo osservato | Dipendenza e failure mode | Verifica read-only |
|---|---|---|---|
| DNS | 53 TCP/UDP | zona `lab.test`; se indisponibile falliscono risoluzione e join | `Get-DnsServerZone` |
| Kerberos/KDC | 88 TCP/UDP | AD DS; se indisponibile fallisce SSO/join | `Get-NetTCPConnection -State Listen` |
| LDAP/LDAPS | 389/636 TCP | AD DS; binding e CA client non verificati | `Get-Service NTDS` |
| Global Catalog | 3268/3269 TCP | AD DS; ricerca directory degradata | `Get-ADDomain` |
| Amministrazione | RDP 3389, SSH 22, WinRM HTTP 5985 | accesso amministrativo via VPN; policy di esposizione NSG non verificata | `Get-NetTCPConnection -State Listen` |

`SOC-Desktop-Users` è il gruppo consentito da SSSD su VPS12; `SOC-Web-Users` è presente per i servizi web. Database interno AD, SYSVOL, utenti, membership nominative, password e materiale di chiave non sono stati esportati né documentati.
