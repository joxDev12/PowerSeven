# DNS

Verifica diretta read-only su DC02 del 25 settembre 2026: le zone sono `_msdcs.lab.test`, `lab.test`, reverse locali e `TrustAnchors`. La ricerca di record A con indirizzo `10.20.20.*` non ha restituito risultati; non è stata rilevata una configurazione DNS legacy attiva.

La zona AD-integrata `lab.test` contiene `adguard`, `cloud`, `git`, `login`, `panel`, `pdf`, `scribble`, `scribble-2`, `wazuh` e `wings` verso `10.10.10.14`. `dc02` è registrato con `10.10.10.13` e `172.16.0.4`; sono presenti anche i record di zona directory a `10.10.10.13`. VPS12 usa DC02 (`10.10.10.13`) come DNS; DC02 usa `10.10.10.14` come forwarder; AdGuard risponde su `10.10.10.14:53` TCP/UDP e inoltra a Internet.

| Ruolo | Host/protocollo | Health check read-only | Failure mode |
|---|---|---|---|
| Autoritativo AD | DC02, DNS 53 TCP/UDP | `Get-DnsServerResourceRecord -ZoneName lab.test` | nomi interni non risolti |
| Resolver client | VPS12 → `10.10.10.13` | `resolvectl status` | desktop senza DNS/AD |
| Forwarder | DC02 → AdGuard `10.10.10.14:53` | `Get-DnsServerForwarder` | query esterne falliscono |
| Filtro/upstream | AdGuard VPS14 → Internet | `sudo docker ps` | DNS esterno degradato |

La catena è rappresentata in [DNS/AD](../diagrams/dns-active-directory.html). Non sono stati verificati la policy di filtro AdGuard, gli upstream specifici o il caching.
