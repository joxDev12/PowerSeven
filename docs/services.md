# Servizi VPS14

VPS14 (`soc-server`, `10.10.10.14`) ospita il proxy, i container e i servizi centrali. Nginx ascolta su TCP 80/443 e termina/passa HTTPS ai backend; l'autenticazione applicativa, salvo l'integrazione LDAP prevista per Nextcloud, Forgejo e portale, non è verificata.

| DNS | Processo/container e porta osservati | Dipendenza/storage | Health check read-only e failure mode |
|---|---|---|---|
| `cloud.lab.test` | Nextcloud Docker, `127.0.0.1:8083` | PostgreSQL e Redis dichiarati; configurazione effettiva non verificata | `curl -kI https://cloud.lab.test`; guasto Nginx, container o DB |
| `git.lab.test` | Forgejo Docker, `127.0.0.1:3001` | PostgreSQL dichiarato; LDAP non verificato | `curl -kI https://git.lab.test`; guasto proxy/container/DB |
| `pdf.lab.test` | Stirling PDF Docker, `127.0.0.1:8084` | storage e autenticazione non verificati | `curl -kI https://pdf.lab.test`; guasto proxy/container |
| `adguard.lab.test` | AdGuard Docker, UI `127.0.0.1:3002`; DNS `10.10.10.14:53` TCP/UDP | upstream DNS Internet | `sudo docker ps`; guasto DNS esterno o container |
| `panel.lab.test` | Pterodactyl locale; worker `pteroq` | MariaDB `panel` | `systemctl status pteroq`; guasto panel/queue/DB |
| `wazuh.lab.test` | Wazuh Dashboard `127.0.0.1:8443` | Indexer e Manager locali | `systemctl status wazuh-dashboard wazuh-indexer`; guasto dashboard/indexer |
| `wings.lab.test` | Wings `127.0.0.1:8080`, SFTP TCP 2022 | Pterodactyl; configurazione panel non verificata | `systemctl status wings`; guasto daemon/panel |
| `login.lab.test` | `azienda-portal` Gunicorn `127.0.0.1:5000` | LDAP previsto; database non verificato | `systemctl status azienda-portal`; guasto processo/LDAP |
| `scribble*.lab.test` | due container, `10.10.10.14:8081/8082` TCP/UDP | storage/autenticazione non verificati | `sudo docker ps`; guasto container/rete Docker |

La pubblicazione Internet effettiva dipende dall'Azure NSG e non è deducibile dal solo listener host: vedere [sicurezza](security.md). Vedere anche [diagramma servizi](../diagrams/vps14-services.html).
