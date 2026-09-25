# Disaster recovery

Backup, retention, repository, RPO, RTO e un test di ripristino non sono verificati: non assumere che esistano. Le chiavi WireGuard, certificati, password, dump e file `.env` devono restare in un deposito sicuro fuori dal repository.

| Asset | Dato da proteggere | Dipendenza / failure mode | Verifica read-only da pianificare |
|---|---|---|---|
| DC02 | AD System State, DNS, SYSVOL | senza AD/DNS falliscono identità e risoluzione | inventario job e ultimo restore: non verificato |
| VPS14 rete | configurazione WireGuard, Nginx e firewall host | senza hub/proxy manca accesso e pubblicazione | presenza backup/versioning: non verificato |
| PostgreSQL/MariaDB/Redis | database, configurazione e dati persistenti | applicazioni non ripristinabili | catalogo backup e restore test: non verificati |
| Docker | volumi, Compose/configurazione, immagini necessarie | servizi container non ripristinabili | elenco volumi e backup: non verificato |
| Wazuh | configurazione, indici e retention richiesta | perdita di telemetria/storico | policy e backup: non verificati |
| VPS12 | configurazione XRDP/SSSD e dati locali necessari | postazione SOC non disponibile | immagine/backup: non verificato |

Ordine di ripristino proposto: DC02/DNS → WireGuard VPS14 → database → Nginx/Docker/servizi → VPS12/XRDP → agenti Wazuh. Testare in ambiente isolato senza sovrascrivere produzione; questo ordine è una raccomandazione architetturale, non un runbook già validato.
