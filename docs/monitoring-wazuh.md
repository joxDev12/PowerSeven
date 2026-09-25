# Monitoring Wazuh

VPS14 esegue Wazuh Manager 4.14.8, Indexer e Dashboard. Il Manager ascolta su 1514/1515, l'API su 55000 e Dashboard è locale su `127.0.0.1:8443`, pubblicata da Nginx come `wazuh.lab.test`. Il binding dettagliato di ogni porta e l'autenticazione API non sono verificati.

| Componente | Host e ruolo | Dipendenze | Health check read-only | Failure mode |
|---|---|---|---|---|
| Manager | VPS14; riceve agenti | Indexer/servizi Wazuh | `sudo systemctl status wazuh-manager` | eventi non ingeriti |
| Indexer/Dashboard | VPS14; indicizzazione e UI HTTPS via Nginx | Manager e storage locale non verificato | `sudo systemctl status wazuh-indexer wazuh-dashboard` | ricerca/UI indisponibili |
| Agent | VPS12 4.14.8 → `10.10.10.14:1514/TCP` | WireGuard e Manager | `systemctl status wazuh-agent` | desktop senza telemetria |
| Agent | DC02, servizio `WazuhSvc` attivo | Manager; indirizzo configurato non verificato direttamente | `Get-Service WazuhSvc` | DC senza telemetria |

I log Dashboard indicavano due agenti monitorati al momento della verifica. Retention, indici, credenziali, certificati e backup Wazuh non sono verificati.
