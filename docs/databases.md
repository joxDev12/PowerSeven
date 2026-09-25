# Database

I database sono su VPS14. PostgreSQL 18.6 ascolta su `127.0.0.1:5432` e `10.10.10.14:5432`; database non-template osservati: `azienda_lab`, `forgejo`, `nextcloud`, `postgres`. MariaDB 10.11.14 ascolta su `127.0.0.1:3306`; `panel` è il database applicativo osservato di Pterodactyl. Redis di sistema ascolta su `127.0.0.1:6379`; esiste anche un Redis isolato nella rete Docker di Nextcloud.

| Motore | Consumatori | Autenticazione/storage | Health check read-only | Failure mode |
|---|---|---|---|---|
| PostgreSQL | Forgejo e Nextcloud dichiarati; `azienda_lab` osservato | ruoli, password, TLS, volumi e backup non verificati | `sudo -u postgres psql -c '\\l'` | applicazioni senza persistenza o login |
| MariaDB | Pterodactyl `panel` | credenziali, socket config e backup non verificati | `sudo systemctl status mariadb` | panel/worker degradati |
| Redis locale | consumatore non verificato | persistenza e ACL non verificate | `sudo systemctl status redis-server` | cache/queue dipendente degradata |
| Redis Docker | Nextcloud dichiarato | volume, password e policy non verificati | `sudo docker ps` | Nextcloud degradato |

I nomi e host dichiarati per Forgejo, Nextcloud e Pterodactyl indicano rispettivamente PostgreSQL, PostgreSQL e MariaDB, ma nessuna stringa di connessione completa, segreto o dump è inclusa. L'ascolto su un IP VPN non equivale a esposizione Internet: è soggetto a routing, NSG e firewall; vedere [sicurezza](security.md).
