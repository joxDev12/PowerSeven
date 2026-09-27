# VPS14 optimization audit

Fonte: discovery Azure e validazione controllata VPS14 del 26 settembre 2026.
Il tuning Indexer Wazuh è stato validato live; il Manager resta stock.

## Priorità

1. Non avviare stack incompatibili insieme: è il risparmio principale.
2. Rendere tutte le restart policy Docker `no` nel target locale.
3. Mantenere Wazuh Indexer nel profilo WAZUH con il tuning validato e misurare
   sulla VM locale prima di dichiarare sufficiente la RAM.
4. Tenere MariaDB/Redis e worker on-demand; PostgreSQL segue Forgejo/Nextcloud.

## Matrix

| Componente | CURRENT misurato | PROPOSED | Risparmio RAM stimato | Rischio | Reversibile | Restart |
|---|---|---|---:|---|---|---|
| Wazuh Indexer JVM | tuning validato: cgroup ~0.95–1.05 GiB, heap 512/512 MiB, direct 256 MiB | provisioning tramite role `wazuh_server`; nessun nuovo tuning | ~0.8 GiB rispetto alla baseline storica | GC/indexing burst | sì | sì |
| Wazuh Dashboard | cgroup 187 MiB, Node PSS 209 MiB | profilo WAZUH; cap Node solo se il test UI passa | ~0.05 GiB | crash su ricerche grandi | sì | sì |
| Wazuh Manager | validato fresh-start: cgroup ~0.40–0.45 GiB; 2.36 GiB resta osservazione storica non spiegata | Manager stock; caratterizzare moduli prima di intervenire | non applicato | perdita inventory/vulnerability | sì | sì |
| PostgreSQL | `postgresql@18-main.service`, cgroup 47.7 MiB baseline; Forgejo/Nextcloud consumer | shared dependency concreta; union desired-state; stop solo senza consumer | 0 fino a stop reale | applicazioni DB down se fermato | sì | no |
| Forgejo | container 193.2 MiB baseline; pool default; no Docker healthcheck | `restart="no"`, pool 20/2, idle timeout 10m, HTTP healthcheck | non promesso | burst DB accodati oltre 20 connessioni | sì | sì |
| MariaDB | cgroup 146 MiB, InnoDB pool 128 MiB, max 151 | on-demand PTERODACTYL; pool 64 MiB/max 50 | ~0.06 GiB | panel più lento | sì | sì |
| Redis | RSS 13 MiB, usati 1.13 MiB, nessun maxmemory | on-demand PTERODACTYL; Redis Nextcloud nel profilo | ~0.01 GiB | queue/cache indisponibile | sì | no |
| Nextcloud | app 177 MiB baseline, cron 1.6 MiB, Redis 9.1 MiB; limiti 2 GiB/512 MiB/256 MiB | `restart: "no"`; controller service-level; APCu/Redis/cron invariati | 0 | cache/DB indisponibili quando spento | sì | sì |
| Docker | daemon PSS 183 MiB, cgroup 203 MiB; `containerd` segue Docker; container live | opzione A corrente: Docker CORE per AdGuard; container gestiti dal controller | non attribuito | app non disponibile finché non parte il controller | sì | no |
| containerd | dipendenza Docker; misura separata non isolata nella discovery | seguire Docker in opzione A; misurare cgroup separato nel rebuild | 0 | AdGuard/Docker indisponibili se fermato | sì | no |
| AdGuard container | 126.9 MiB live, limite 512 MiB, `unless-stopped` | CORE in opzione A; `restart: "no"` nel target locale | 0 | DNS finale DC02 indisponibile | sì | no |
| AdGuard nativo | non implementato | opzione B futura; Docker può diventare on-demand se nessun CORE consumer resta | non garantito | migrazione/fallback DNS | sì | sì |
| Nginx | cgroup 7 MiB, 5 processi | CORE | 0 | backend off se profilo off | sì | no |
| Gunicorn portal | cgroup 45 MiB, 1 worker | dashboard CORE; mantenere 1 worker e health check | 0 | dashboard down se il servizio fallisce | sì | no |
| Pterodactyl worker | pteroq 39 MiB, Wings 24 MiB | PTERODACTYL on-demand; nessun game server automatico | ~0.12 GiB + workload | queue/daemon off | sì | no |
| journald | 29.7 MiB su disco | limitare retention nella nuova immagine; non venderla come RAM saving | ~0 | perdita storico | sì | no |
| Servizi Ubuntu/Azure | ModemManager, multipathd, Azure agent e altri enabled | omettere Azure-only nel target locale; review ModemManager/multipathd | ~0.08 GiB | integrazione piattaforma/storage | sì | sì |

I numeri cgroup e PSS non sono additivi: i processi condividono librerie e il
kernel/cache sono contabilizzati diversamente. Il risparmio affidabile è la
sottrazione degli stack spenti, non la somma di ogni riga.

## Wazuh

Wazuh è il profilo determinante. La configurazione live validata imposta:

```text
Indexer: -Xms512m -Xmx512m -XX:MaxDirectMemorySize=256m
Indexer: cgroup stabilizzato ~0.95–1.05 GiB
Manager: cgroup stabilizzato ~0.40–0.45 GiB
Dashboard + Filebeat: ~180 MiB
Totale Wazuh: ~1.5–1.6 GiB
```

Con il tuning validato, il target iniziale VPS14 locale è 4 vCPU, 5 GiB RAM e
40 GiB thin disk, espandibile in seguito. 5 GiB è raccomandato ma deve ancora essere validato sulla VM
locale; 4 GiB resta sperimentale; 6 GiB è il fallback se emerge pressione.
Wazuh resta on-demand e normalmente OFF.

Il tuning è una responsabilità del role
`iac/ansible/roles/wazuh_server/defaults/main.yml`, non del controller. Il
controller mantiene l'ordine Indexer → Manager → Filebeat → Dashboard e lo
stop inverso; startup osservato ~30–40 s.

## Database

PostgreSQL non è CORE: la dashboard è AD-only. Forgejo e Nextcloud lo
dichiarano come dipendenza condivisa; il controller usa la loro unione di
stato attivo e non un refcount persistente. MariaDB serve Pterodactyl; Redis
host serve Pterodactyl/queue e il Redis Docker serve Nextcloud.

## Docker e boot

La discovery live comprende AdGuard, Forgejo, Stirling, tre container Nextcloud
e due Scribble unmanaged. Forgejo e Nextcloud usano `restart: "no"` e delegano
l'avvio alle unità PowerSeven; AdGuard e Stirling restano fuori perimetro.
Questo elimina il bypass del controller senza cambiare il runtime da Docker a
Podman. Opzione A è la scelta corrente; opzione B, AdGuard nativo/Docker
on-demand, richiede test DNS e non è stata applicata.

## Risorse immagine locale

Nell'immagine locale non servono l'Azure Linux Agent e i componenti specifici
del kernel/provider Azure. `ModemManager`, `multipathd`, `open-iscsi`,
`nvmefc`/`nvmf` e `udisks2` restano candidati: vanno esclusi solo dopo avere
verificato il percorso storage VMware. Nessun servizio Azure corrente è stato
disabilitato per fare questa misura.
