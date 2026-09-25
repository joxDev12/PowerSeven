# Database

PostgreSQL 18.6 è attivo e in ascolto su `127.0.0.1:5432` e `10.10.10.14:5432`. Database non-template osservati: `azienda_lab`, `forgejo`, `nextcloud`, `postgres`.

MariaDB 10.11.14 è attivo su `127.0.0.1:3306`; database applicativo osservato: `panel` (Pterodactyl). Redis locale è attivo su `127.0.0.1:6379` e il container Redis Nextcloud è isolato nella rete Docker.

I nomi e host dichiarati per Forgejo, Nextcloud e Pterodactyl confermano rispettivamente PostgreSQL, PostgreSQL e MariaDB. Nessuna stringa di connessione completa o password è documentata.
