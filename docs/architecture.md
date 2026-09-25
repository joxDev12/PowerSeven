# Architettura

La topologia verificata è illustrata in [diagramma generale](../diagrams/architecture-overview.html). VPS14 è il punto di concentrazione: termina WireGuard, ospita Nginx e i servizi centrali. VPS12 dipende da DC02 per DNS/identità AD e invia telemetria a Wazuh su VPS14. DC02 inoltra le query DNS esterne a VPS14.

È operativo un solo overlay: `wg-final` sulla rete `10.10.10.0/24`. L'overlay temporaneo usato durante la migrazione è stato rimosso dalle tre VM e non fa parte dell'architettura operativa.

## Evidenza runtime

Le tre VM rispondevano via SSH. `wg-final`, XRDP, AD DS/DNS, Nginx, Docker, PostgreSQL, Wazuh e Wings risultavano attivi; i backend HTTP locali di VPS14 hanno risposto con codici applicativi attesi (200, 302 o 401).
