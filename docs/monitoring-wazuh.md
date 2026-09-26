# Monitoring Wazuh

VPS14 esegue Wazuh Manager 4.14.8, Indexer, Dashboard e Filebeat. Il Manager ascolta su 1514/1515, l'API su 55000, l'Indexer solo su `127.0.0.1:9200` e Dashboard su `0.0.0.0:8443`, pubblicata da Nginx come `wazuh.lab.test`. Il lifecycle PowerSeven è `powerseven-app-wazuh.service`, disabilitato al boot insieme alle quattro unità native, con ordine Indexer → Manager → Filebeat → Dashboard e stop inverso.

| Componente | Host e ruolo | Dipendenze | Health check read-only | Failure mode |
|---|---|---|---|---|
| Manager | VPS14; riceve agenti | Indexer/servizi Wazuh | `sudo systemctl status wazuh-manager` | eventi non ingeriti |
| Indexer/Dashboard | VPS14; indicizzazione e UI HTTPS via Nginx | Manager, Filebeat e storage locale | `powerseven-app-wazuh.service` | ricerca/UI indisponibili |
| Agent | VPS12 4.14.8 → `10.10.10.14:1514/TCP` | WireGuard e Manager | `systemctl status wazuh-agent` | desktop senza telemetria |
| Agent | DC02, servizio `WazuhSvc` attivo | Manager; indirizzo configurato non verificato direttamente | `Get-Service WazuhSvc` | DC senza telemetria |

I log Dashboard indicavano due agenti monitorati al momento della verifica. Retention, indici, credenziali, certificati e backup Wazuh non sono verificati.
