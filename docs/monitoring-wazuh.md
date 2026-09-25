# Monitoring Wazuh

VPS14 esegue Wazuh Manager 4.14.8, Indexer e Dashboard. Manager ascolta su 1514 e 1515; Dashboard è locale su 8443 e pubblicata da Nginx come `wazuh.lab.test`. L'API è in ascolto su 55000.

VPS12 esegue Wazuh agent 4.14.8, configurato verso `10.10.10.14:1514/TCP`. Il servizio Wazuh su DC02 è in esecuzione. I log Dashboard indicavano due agenti monitorati al momento della verifica.
