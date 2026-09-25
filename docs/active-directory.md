# Active Directory

DC02 è Windows Server 2022 Datacenter e l'unico controller rilevato di `LAB.TEST`/`lab.test`. AD DS e DNS sono installati; DC02 detiene tutti i ruoli FSMO. Il dominio è in modalità Windows Server 2016.

Kerberos (`88` TCP/UDP), LDAP (`389`), LDAPS (`636`), Global Catalog (`3268/3269`), DNS (`53`) e RPC/SMB sono in ascolto. RDP (`3389`), OpenSSH (`22`) e WinRM HTTP (`5985`) sono anch'essi attivi.

Gruppi di interesse: `SOC-Desktop-Users` è il gruppo consentito da SSSD su VPS12; `SOC-Web-Users` è presente per i servizi web. Non sono stati copiati utenti, membership nominative o credenziali.
