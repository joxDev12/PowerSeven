# DNS

Verifica diretta read-only su DC02 del 25 settembre 2026: le zone sono `_msdcs.lab.test`, `lab.test`, reverse locali e `TrustAnchors`. La ricerca di record A con indirizzo `10.20.20.*` non ha restituito risultati; non è stata rilevata una configurazione DNS legacy attiva.

La zona AD-integrata `lab.test` contiene `adguard`, `cloud`, `git`, `login`, `panel`, `pdf`, `scribble`, `scribble-2`, `wazuh` e `wings` verso `10.10.10.14` sull'overlay. `dc02` usa `192.168.214.13` sull'underlay; VPS12 e VPS14 usano DC02 come DNS; DC02 inoltra a AdGuard `192.168.214.14` sull'underlay. I record applicativi restano raggiungibili via WireGuard.

## VPS14 e `wg-final`

VPS14 usa split DNS per il solo dominio `~lab.test`: l'interfaccia WireGuard `wg-final` resta gestita da `wg-quick` e non da `systemd-networkd`. La configurazione persistente è il servizio `powerseven-wg-final-dns.service`, applicato quando il device unmanaged esiste:

- DNS autorevole per `lab.test`: DC02 `10.10.10.13`;
- `panel.lab.test`: `10.10.10.14`;
- fallback DNS Internet: il resolver già configurato sull'interfaccia normale;
- ripristino in stop: `resolvectl revert wg-final`.

Non devono essere creati file `.network` per `wg-final` e non devono essere modificati routing, peer o chiavi WireGuard.

Il certificato pubblico storico `SOC Lab Training CA` è stato recuperato da VPS12 e installato nel trust store di VPS14 in `/usr/local/share/ca-certificates/powerseven-soc-lab-ca.crt`. Fingerprint SHA-256: `5B:04:DC:62:6B:5C:1B:61:EB:C0:66:A5:82:AF:D7:73:84:5B:BA:55:A0:FD:8B:EF:06:B2:FE:BF:4E:35:5D:EC`. Il certificato non è versionato nel repository; private key e materiale PKCS#12 non devono essere copiati o committati.

| Ruolo | Host/protocollo | Health check read-only | Failure mode |
|---|---|---|---|
| Autoritativo AD | DC02, DNS 53 TCP/UDP | `Get-DnsServerResourceRecord -ZoneName lab.test` | nomi interni non risolti |
| Resolver client | VPS12 → `10.10.10.13` | `resolvectl status` | desktop senza DNS/AD |
| Forwarder | DC02 → AdGuard `10.10.10.14:53` | `Get-DnsServerForwarder` | query esterne falliscono |
| Filtro/upstream | AdGuard VPS14 → Internet | `sudo docker ps` | DNS esterno degradato |

La catena è rappresentata in [DNS/AD](../diagrams/dns-active-directory.html). Non sono stati verificati la policy di filtro AdGuard, gli upstream specifici o il caching.
