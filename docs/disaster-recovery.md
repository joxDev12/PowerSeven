# Disaster recovery

Non è stata verificata una strategia di backup o un ripristino: non assumere che esista. Prima di una modifica, definire backup coerenti per PostgreSQL, MariaDB, volumi Docker, `/etc/wireguard`, configurazioni Nginx/Wazuh e Active Directory System State; le chiavi devono restare in deposito sicuro fuori dal repository.

Priorità di ripristino: DC02/DNS → WireGuard VPS14 → database → Nginx/Docker/servizi → VPS12/XRDP → agenti Wazuh. Testare periodicamente il ripristino in un ambiente isolato, senza sovrascrivere la produzione.
