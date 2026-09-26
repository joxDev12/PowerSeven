# VPS14 service profiles

Discovery read-only eseguita il 26 settembre 2026 via SSH su
`serveradmin@10.10.10.14`, usando solo l'indirizzo VPN. Non sono stati
eseguiti installazioni, start/stop/restart, cambi firewall, Azure o WireGuard.

## Evidenze live

VPS14 è Ubuntu 24.04.4 su Azure, 15 GiB RAM, swap assente, uptime 2 giorni e
2 ore al momento della misura. `free -b` ha riportato 5.39 GiB usati,
0.65 GiB liberi e 10.23 GiB disponibili. Il dato `used` include cache; i dati
di processo/cgroup sotto sono più utili per dimensionare i profili.

### Top 15 RSS

| Processo | RSS | PSS | Nota |
|---|---:|---:|---|
| Wazuh Indexer Java | 1,727 MiB | 1,723 MiB | heap 1 GiB, direct 512 MiB |
| Stirling Java | 870 MiB | 868 MiB | include conversione PDF |
| `wazuh-modulesd` | 515 MiB | 505 MiB | Manager |
| Wazuh Dashboard Node | 212 MiB | 209 MiB | ascolto live `0.0.0.0:8443` |
| Forgejo | 180 MiB | 180 MiB | container |
| AdGuard Home | 153 MiB | 153 MiB | container |
| Docker daemon | 147 MiB | 144 MiB | cgroup Docker 203 MiB |
| MariaDB | 139 MiB | 133 MiB | InnoDB pool 128 MiB |
| Wazuh API Python | 133 MiB | 114 MiB | cgroup Manager |
| Apache2 | 124 MiB | 32 MiB | Nextcloud container, pagine condivise |
| `wazuh-analysisd` | 120 MiB | 117 MiB | Manager |
| Apache2 | 119 MiB | 29 MiB | Nextcloud container |
| Apache2 | 112 MiB | 23 MiB | Nextcloud container |
| Apache2 | 111 MiB | 23 MiB | Nextcloud container |
| Apache2 | 107 MiB | 22 MiB | Nextcloud container |

### Container

| Container | RAM live | Limite | PIDs | Health | Restart policy |
|---|---:|---:|---:|---|---|
| AdGuard | 126.9 MiB | 512 MiB | 8 | assente | `unless-stopped` |
| Forgejo | 190.9 MiB | 1 GiB | 12 | assente | `unless-stopped` |
| Stirling | 917.1 MiB | 2 GiB | 54 | healthy | `unless-stopped` |
| Nextcloud cron | 1.5 MiB | 512 MiB | 1 | assente | `unless-stopped` |
| Nextcloud app | 177 MiB | 2 GiB | 9 | assente | `unless-stopped` |
| Nextcloud Redis | 8.8 MiB | 256 MiB | 6 | assente | `unless-stopped` |
| Scribble 8082 | 26.7 MiB | 2.3 GiB | 8 | assente | `no` |
| Scribble 8081 | 26.7 MiB | 2.3 GiB | 8 | assente | `no` |

Le restart policy live bypassano il controller per AdGuard, Forgejo, Stirling
e tutto Nextcloud. Il target locale dichiarativo è stato corretto a
`restart: "no"`; la VPS14 Azure non è stata modificata.

### Cgroup e systemd

| Unità | Cgroup | PSS/processi |
|---|---:|---:|
| `wazuh-manager.service` | 2,366 MiB | 970 MiB / 14 |
| `wazuh-indexer.service` | 1,793 MiB | 1,723 MiB / 1 |
| `wazuh-dashboard.service` | 187 MiB | 209 MiB / 1 |
| `docker.service` | 203 MiB | 183 MiB / 11 |
| `mariadb.service` | 146 MiB | 141 MiB / 1 |
| `postgresql@18-main.service` | 97 MiB | 49 MiB / 11 |
| `azienda-portal.service` | 45 MiB | 48 MiB / 2 |
| `pteroq.service` | 39 MiB | 48 MiB / 1 |
| `wings.service` | 24 MiB | 36 MiB / 1 |
| `redis-server.service` | 9 MiB | 10 MiB / 1 |
| `nginx.service` | 7 MiB | 8 MiB / 5 |

Wazuh Manager cgroup include API, database, analysisd, remoted, authd,
modulesd e gli altri processi Wazuh; per questo la somma dei singoli RSS non
va sommata due volte al cgroup.

## Autostart audit

Servizi applicativi o pesanti attivi e abilitati al boot oggi:

```text
docker containerd nginx
postgresql.service postgresql@18-main.service
mariadb redis-server php8.3-fpm
azienda-portal pteroq wings
filebeat
wazuh-indexer wazuh-manager wazuh-dashboard
```

WireGuard reale è `wg-quick@wg0.service`, attivo e abilitato. L'unità
`wg-quick@wg-final.service` non è quella usata dalla VPS14 osservata. SSH è
attivo tramite `ssh.socket` attivo/abilitato; `ssh.service` risulta disabilitato
come unità tradizionale. Non assumere il nome live come nome definitivo del
rebuild locale: verificarlo dopo la configurazione WireGuard locale.

Altri enabled osservati sono principalmente base OS/cloud: `chrony`, `cron`,
`systemd-networkd`, `systemd-resolved`, `rsyslog`, `ufw`, `unattended-upgrades`,
`walinuxagent`, `ModemManager`, `multipathd`, `open-iscsi`, `open-vm-tools`,
`udisks2`, `snapd` e servizi Hyper-V. `ModemManager`, `multipathd` e i servizi
Azure sono candidati da valutare nella nuova immagine Ubuntu, non da disabilitare
sulla VPS14 corrente.

Timer/cron rilevanti: `pterodactyl` ogni minuto, pulizia sessioni PHP ogni 30
minuti, sysstat ogni 10 minuti, più timer standard apt/logrotate/man-db. Non
sono stati modificati.

## CORE definitivo

MUST STAY ON:

- WireGuard (`wg-quick@<unit-locale>.service`) e `ssh.socket`;
- Nginx, per la dashboard permanente;
- `azienda-portal.service`/Gunicorn, dashboard PowerSeven;
- AdGuard Home, resolver finale di DC02;
- `cockpit.socket`, con accesso futuro solo dalla VPN;
- `postgresql.service` come CORE temporaneo, perché la dashboard usa oggi
  `azienda_lab` (`postgresql_core_reason: dashboard_current_dependency`).

Docker è CORE nella scelta corrente A perché AdGuard è un container. `containerd`
segue Docker. La scelta futura B (AdGuard nativo e Docker on-demand) non è
implementata: richiede fallback DNS verificato su DC02 e una nuova misura del
risparmio. AdGuard live pesa 126.9 MiB container / ~153 MiB RSS; Docker daemon
ha 183 MiB PSS e cgroup 203 MiB. Il passaggio nativo non ha quindi un
risparmio garantito sufficiente a giustificare ora il cambio.

La futura integrazione AD/LDAP può rendere PostgreSQL on-demand solo dopo aver
migrato la dashboard e verificato che nessun altro componente CORE usi
`azienda_lab`. È una FUTURE OPTIMIZATION / NOT IMPLEMENTED.

## Matrice profili

| Profilo | Stack avviato | Dipendenze/start order | Stop order | Porte | Health check | RAM pianificata |
|---|---|---|---|---|---|---:|
| CORE | WG, SSH, Docker/containerd, AdGuard, PostgreSQL, dashboard, Nginx, Cockpit socket | rete → SSH → Docker → AdGuard → PostgreSQL → dashboard → health → Nginx | mai tramite kill switch | 22, 53, 80, 443, 51820, 9090 | unità + DNS + dashboard | 2.0 GiB peak |
| NEXTCLOUD | PostgreSQL; Redis/app/cron `soc-cloud` | CORE → PostgreSQL → Redis → app → cron | cron → app → Redis | 8083 locale, 443 | `/status.php` 200 | 2.5 GiB |
| FORGEJO | PostgreSQL; Forgejo `soc-forgejo` | CORE → PostgreSQL → Forgejo | Forgejo | 3001 locale, 443 | HTTP 200 | 2.3 GiB |
| STIRLING | Stirling PDF | CORE → container | Stirling | 8084 locale, 443 | Docker healthy/HTTP | 3.2 GiB |
| PTERODACTYL | MariaDB, Redis, PHP-FPM, pteroq, Wings | CORE → DB/cache → PHP → queue → Wings | Wings → queue → PHP → cache → DB | 8080 locale, 2022, 443 | DB/panel/Wings | 1.8 GiB control plane; 4 GiB con un server da 2 GiB |
| WAZUH | Indexer, Filebeat, Manager, Dashboard | CORE → Indexer → Filebeat/Manager → Dashboard | Dashboard → Manager → Filebeat → Indexer | 1514, 1515, 55000, 443 | unità/API/UI | 5.0 GiB target; 4 GiB sperimentale |
| PORTAL | componente CORE: PostgreSQL, Gunicorn 1 worker, dashboard health | CORE → PostgreSQL → portal → health | mai tramite profilo optional | 5000 locale, 443 | HTTP 200 sempre disponibile | incluso in CORE |
| SCRIBBLE | due container Scribble | CORE → scribble-1/2 | 2 → 1 | 8081/8082 locali, 443 | TCP 8081/8082 | 1.8 GiB |
| ALL-OFF-OPTIONAL | nessun optional | CORE → stop controller | tutti gli optional | solo CORE | CORE + dashboard HTTP 200 | 2.0 GiB peak |

Le stime sono planning envelope, non somma cieca degli RSS. Si basano sui
cgroup live, sui limiti Compose e su un margine OS; il profilo Wazuh richiede
validazione locale dopo la riduzione heap. Pterodactyl esclude il carico reale
dei game server: due container live dichiarano `SERVER_MEMORY=2048` ciascuno.

`PORTAL` resta nel catalogo solo per compatibilità dell’inventory: è un
componente CORE non selezionabile, non un profilo applicativo opzionale.

## Design systemd e kill switch

Ogni profilo è un `Type=oneshot`, `RemainAfterExit=yes`, visibile come servizio
normale in Cockpit. `Requires=powerseven-core.target` e `After=` avviano le
dipendenze; `Conflicts=` rende incompatibili i profili. `ExecStart` e `ExecStop`
chiamano un controller con allowlist fissa; `ExecStartPost` esegue l'health
check. Le dipendenze condivise non vengono fermate durante lo switch e vengono
fermate solo da `powerseven-stop-all-optional.service`.

Il kill switch lascia sempre attivi WireGuard, SSH, Docker/containerd, Nginx,
AdGuard, Cockpit socket, dashboard e PostgreSQL finché la dashboard usa
`azienda_lab`. Non contiene né invoca stop su unità CORE. La validazione
statica rifiuta eventuali stop su unità protette, cicli, dipendenze mancanti,
healthcheck assenti, RAM assente o restart policy diversa da `no`.

Il control plane è separato: Dashboard = visualizzazione/status read-only;
Cockpit = GUI tecnica; systemd = autorità; `powerseven-service` = allowlist;
Compose = runtime. La dashboard legge `/run/powerseven/active-profile` e gli
altri file di stato 0644, non esegue shell root e non controlla profili.

Se una transizione fallisce, il controller scrive `FAILED` e `last-failure`,
termina senza retry loop e non tocca CORE. Dashboard, Nginx e Cockpit restano
disponibili per la diagnosi.

La dichiarazione e i template sono in
[`iac/service-control/`](../iac/service-control/README.md).

## RAM target

| VPS14 locale | Profili plausibili |
|---:|---|
| 3 GiB | CORE e profili leggeri; Nextcloud/Forgejo/Stirling solo con margine ridotto; Wazuh e game workload esclusi |
| 4 GiB | optimization target da validare; profili leggeri e Wazuh solo dopo load test, non garantito |
| 5 GiB | recommended initial VPS14; un profilo alla volta, Wazuh tuned o un game server ~2 GiB da validare |
| 6 GiB | fallback per Wazuh attuale non ottimizzato o due game server ~2 GiB |

Conclusione: 6 GiB non è un requisito architetturale. Il minimo pratico locale
è 3 GiB per CORE/profili leggeri; il target di ottimizzazione è 4 GiB, senza
garanzia Wazuh; 5 GiB è la raccomandazione iniziale. Heap Indexer 512m/direct
256m resta EXPERIMENTAL e REQUIRES LOAD TEST; non è stato applicato su Azure.
