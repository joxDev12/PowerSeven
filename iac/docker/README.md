# Application deployment

`compose.yml` è un target dichiarativo per servizi nuovi e vuoti. Non contiene
dati Azure, restore, immagini con tag inventati o secret.

Servizi inclusi: AdGuard Home, Nextcloud, Forgejo, Stirling PDF, Scribble e
Redis applicativo. PostgreSQL/MariaDB restano contratti host-level Ansible e
sono raggiunti tramite variabili di connessione. Nel target service-profile
ogni servizio usa `restart: "no"`: systemd/controller decide cosa avviare.

Prima di un futuro `docker compose config` il renderer deve sostituire i tag
`REQUIRED_DECISION` con versioni approvate.
