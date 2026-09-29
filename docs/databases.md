# Database foundation (CP5)

CP5 prepara PostgreSQL e MariaDB come servizi host su VPS14 dopo CP1–CP4. Non
configura ancora login, grant, schema o segreti applicativi e non avvia i
container. Il codice, `iac/inventory/services.yml`, `iac/inventory/storage.yml`,
`iac/versions.yml`, service-control e il grafo sono la fonte del modello.

## Consumatori e dati dichiarati

| Servizio | Motore e database dichiarato | Fonte | Stato CP5 |
|---|---|---|---|
| Forgejo | PostgreSQL, `forgejo` | inventory servizi/storage; dipende da `db_postgresql` | crea solo il database vuoto |
| Nextcloud | PostgreSQL, `nextcloud` | inventory servizi/storage; dipende da `db_postgresql` e Redis container | crea solo il database vuoto |
| Pterodactyl Panel | MariaDB, `panel` | inventory servizi/storage e service-control (`panel_db`) | crea solo il database vuoto |
| PostgreSQL stesso | `postgres` | database standard inizializzato dal pacchetto | verifica e conserva |

`azienda_lab` è soltanto un database legacy osservato nell'ambiente Azure; non
viene creato nel rebuild locale. Compose dichiara gli host/porte e placeholder
di password per Forgejo e Nextcloud, ma non nomi utente o database completi.
Il Panel non è incluso nel Compose. I nomi dei ruoli applicativi, gli schemi e
i grant non sono quindi determinabili con certezza e CP5 non li inventa.

## Contratto CP5

| Motore | Versione e sorgente | Listener | Directory dati | Amministrazione locale |
|---|---|---|---|---|
| PostgreSQL | 18.6, pacchetto `postgresql-18` dal PGDG ufficiale per Ubuntu Noble | `127.0.0.1:5432`, `192.168.214.14:5432` | `/var/lib/postgresql/18/main` | utente OS `postgres` con autenticazione peer su socket Unix |
| MariaDB | 10.11.14, pacchetto Ubuntu Noble `mariadb-server` | `127.0.0.1:3306`, `192.168.214.14:3306` | `/var/lib/mysql` | `root` tramite `unix_socket` su socket Unix |

Le directory devono restare sul filesystem root persistente CP1 e mantenere
owner e permessi restrittivi del pacchetto. Apply non installa/aggiorna un motore
di versione diversa, rifiuta dati già presenti quando manca il relativo
pacchetto, non inizializza cluster PostgreSQL estranei e non esegue upgrade,
drop o reset. Crea solo i database dichiarati che mancano; quelli esistenti e i
relativi contenuti restano intatti.

Il bind underlay è il valore già dichiarato dagli host database in Compose
(`192.168.214.14`), mentre CP3 continua a scartare l'ingresso dalla NIC Bridged
tranne UDP/51820. PostgreSQL mantiene `pg_hba` limitato a connessioni locali e
MariaDB non deve avere account con host remoto. Il TCP listener è quindi
predisposto per una successiva configurazione controllata delle applicazioni,
ma in CP5 non concede autenticazione alle reti remote o Docker. Check verifica
la policy CP3 caricata, i listener esatti e l'assenza di regole/account remoti.

Apply richiede inoltre CP1 storage esteso e le condizioni CP2, CP3 e CP4. Per
evitare di modificare il cluster sbagliato, PostgreSQL deve avere un solo
cluster `18/main` sulla porta 5432; altri cluster vengono preservati e causano
un failure esplicito.

## Segreti e milestone successive

CP5 non richiede password DB: usa solo l'autenticazione locale amministrativa
dei pacchetti. Non scrive segreti nel repository o nei log. Le password
applicative già rappresentate da placeholder restano non configurate; quando
ruoli e connessioni saranno definiti, i valori potranno essere forniti nel file
locale ignorato `iac/docker/.env`, senza committarli. Non aggiungere credenziali
amministrative DB se le connessioni locali peer/socket sono sufficienti.

Prima di avviare Nextcloud o Forgejo servono almeno: decisione esplicita sui
nomi dei ruoli e database applicativi, password locali, grants minimi, policy
PostgreSQL/MariaDB per i client delle reti Docker, immagini/configurazioni,
LDAP/LDAPS e le dipendenze applicative. Pterodactyl Panel richiede ancora il
suo deployment e schema di migrazione. Redis applicativo, CA/certificati,
service-control installabile e AdGuard restano milestone separate. Nessuna di
queste impostazioni è inventata da CP5.

## Porta 53 e AdGuard

Il Check CP5 stampa le righe TCP/UDP della porta 53 con indirizzo e, quando
disponibile, processo. Il precedente Check CP4 registrava soltanto la presenza
di un listener e non identifica il processo LIVE. Su Ubuntu 24.04 il candidato
standard è `systemd-resolved`, che usa il loopback `127.0.0.53` e `127.0.0.54`;
quel bind non collide con Compose, che pubblica AdGuard sull'indirizzo preciso
`192.168.214.14:53`. Un listener wildcard o già legato a `.14` richiede invece
una correzione nella milestone DNS prima dell'avvio di AdGuard. CP5 si limita a
diagnosticare la porta e non modifica il resolver.

## Riferimenti ufficiali

- [Repository PostgreSQL per Ubuntu](https://www.postgresql.org/download/linux/ubuntu/)
- [PostgreSQL `listen_addresses`](https://www.postgresql.org/docs/18/runtime-config-connection.html)
- [PostgreSQL peer authentication](https://www.postgresql.org/docs/18/auth-peer.html)
- [PostgreSQL `pg_hba_file_rules`](https://www.postgresql.org/docs/18/view-pg-hba-file-rules.html)
- [MariaDB `bind_address`](https://mariadb.com/docs/server/server-management/variables-and-modes/server-system-variables)
- [MariaDB `unix_socket`](https://mariadb.com/docs/server/reference/plugins/authentication-plugins/authentication-plugin-unix-socket)
- [Ubuntu 24.04 `systemd-resolved`](https://manpages.ubuntu.com/manpages/noble/man8/systemd-resolved.8.html)
