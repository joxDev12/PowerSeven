# Role contracts

Ogni directory role descrive input, prerequisiti, output e dipendenze. I role
restano contratti finché non contengono task; `wazuh_server` include inoltre
il task idempotente per il profilo JVM Indexer già validato live.
