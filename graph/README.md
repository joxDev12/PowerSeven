# PowerSeven knowledge graph

Questo grafo e la base dichiarativa per IaC locale. Non contiene password,
token, chiavi private o materiale segreto.

## File e modello

`powerseven.graph.json` segue la forma Graphify `nodes`/`links` con metadati
`graph`, piu `hyperedges` per relazioni che coinvolgono piu componenti.
Ogni nodo ha `id`, `label`, `type`, `properties`, `source_file` e `provenance`. Le proprieta
sono nominate per IaC: `hostname`, `os`, `ip`, `network`, `port`, `protocol`,
`service_name`, `systemd_unit`, `container_name`, `docker_network`, `volume`,
`database`, `dns_name`, `config_path`, `dependency`, `startup_order`,
`persistent`, `recreatable`, `secret_required`, `backup_required`.

Tipi di nodo usati: `HOST`, `NETWORK`, `INTERFACE`, `SERVICE`, `APPLICATION`,
`CONTAINER`, `DATABASE`, `DATASTORE`, `DNS_RECORD`, `DOMAIN`,
`IDENTITY_SERVICE`, `USER_GROUP`, `PORT`, `PROTOCOL`, `CERTIFICATE`,
`REVERSE_PROXY`, `MONITORING_AGENT`, `MONITORING_SERVER`, `DEPENDENCY`,
`CONFIGURATION`, `PERSISTENT_DATA`.

Relazioni principali: `RUNS_ON`, `DEPENDS_ON`, `CONNECTS_TO`,
`AUTHENTICATES_AGAINST`, `RESOLVES_THROUGH`, `FORWARDS_TO`, `PROXIES_TO`,
`STORES_DATA_IN`, `MONITORED_BY`, `MEMBER_OF`, `LISTENS_ON`, `ROUTES_TO`,
`USES_CERTIFICATE`, `PERSISTS_IN`, `REQUIRES`, `PROVISIONED_AFTER`, oltre a
`HOSTS`, `CONTAINS` e `USES_PROTOCOL` per il dettaglio operativo.

## Provenienza e confidenza

`provenance` indica il documento o la discovery read-only da cui proviene il
fatto. `confidence` vale `EXTRACTED`, `DECLARED`, `INFERRED` o `UNVERIFIED`.
Un valore non verificato non deve diventare automaticamente una variabile di
provisioning.

Per compatibilita con il validatore Graphify, gli archi owner-declared usano
`confidence: INFERRED` e `assertion_status: DECLARED`; il significato dichiarato
resta esplicito senza usare un valore non ammesso dal validatore.

Azure aveva tre VNet regionali isolate, senza peering. Ogni VNet usava
legittimamente `172.16.0.0/16`, subnet `172.16.0.0/24` e private IP
`172.16.0.4`; la ripetizione non era una collisione. Il target locale usa una
sola rete VMware NAT comune, `net_local_vmware_underlay`, separata dall'overlay
WireGuard `10.10.10.0/24`.

Il grafo distingue `source_current: azure` da `target_local: vmware`. Azure
resta riferimento storico; nessun nodo target locale dipende da una VNet Azure.

`PERSISTENT_DATA` rappresenta stato precedente escluso dal rebuild corrente.
`DATASTORE` rappresenta datastore nuovi e vuoti, ricreabili dal modello.

## Aggiornamento

1. Eseguire discovery read-only e aggiornare prima il fatto nel grafo.
2. Conservare `provenance`, `confidence` e stato di verifica.
3. Aggiornare gli inventari in `iac/inventory/` dal grafo.
4. Validare JSON e riferimenti:

```bash
jq empty graph/powerseven.graph.json
jq '([.nodes[].id] | unique) as $ids | [.links[] | select((.source | IN($ids[] ) | not) or (.target | IN($ids[]) | not))] | length' graph/powerseven.graph.json
```

5. Rieseguire review di segreti e contraddizioni prima di usare il modello per
   provisioning.

## Uso come source of truth IaC

Il grafo descrive il target e le dipendenze; non esegue provisioning. Gli
inventari YAML sono una proiezione operativa versionabile. Un futuro renderer
potra generare Ansible, PowerShell, cloud-init, Compose e test dagli stessi
ID, mantenendo segreti in un secret store esterno.

L'estrazione semantica automatica Graphify non era disponibile in questa
sessione per assenza di provider API. Il modello e stato quindi curato
localmente usando documentazione, Archify e fatti di discovery gia verificati;
`graphify-out/` resta l'artefatto di estrazione tecnica e va rigenerato quando
un provider sara configurato.
