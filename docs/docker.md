# Docker

Docker è in esecuzione su VPS14. I container osservati sono AdGuard, Forgejo, Stirling PDF, Nextcloud (`app`, `cron`, `redis`) e due Scribble. Le reti dedicate osservate sono `soc-adguard_default` (`172.20.0.0/16`), `soc-forgejo_forgejonet` (`172.31.91.0/24`), `soc-stirling_default` (`172.19.0.0/16`), `soc-cloud_cloudnet` (`172.31.90.0/24`) e `pterodactyl_nw` (`172.18.0.0/16`).

| Servizio | Binding/processo | Dipendenze e storage | Verifica read-only / failure mode |
|---|---|---|---|
| AdGuard | UI `127.0.0.1:3002`, DNS `10.10.10.14:53` TCP/UDP | rete Docker e upstream non verificati | `sudo docker ps`; guasto container o DNS upstream |
| Forgejo | `127.0.0.1:3001` | PostgreSQL dichiarato; volume/auth non verificati | `sudo docker ps`; guasto container/DB |
| Nextcloud | `127.0.0.1:8083`, cron e Redis Docker | PostgreSQL e volume dichiarati; dettagli non verificati | `sudo docker ps`; guasto app/Redis/DB |
| Stirling PDF | `127.0.0.1:8084` | storage/auth non verificati | `sudo docker ps`; guasto container |
| Scribble | `10.10.10.14:8081/8082` TCP/UDP | storage/auth non verificati | `sudo docker ps`; binding non disponibile o container fermo |

La maggior parte dei backend è vincolata a loopback; le eccezioni sono AdGuard DNS e Scribble. Nginx raggiunge i backend pubblicati localmente o sull'IP VPN. Non sono stati letti file Compose, volumi o variabili d'ambiente, quindi segreti, mount e configurazioni runtime non sono verificati. Comandi ulteriori senza modifica: `sudo docker network ls`, `sudo docker ps --format '{{.Names}} {{.Ports}}'`.
