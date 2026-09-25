# DNS

La zona AD-integrata `lab.test` su DC02 contiene record A per `adguard`, `cloud`, `git`, `login`, `panel`, `pdf`, `scribble`, `scribble-2`, `wazuh` e `wings`, tutti diretti a `10.10.10.14`. `dc02` dispone di record per rete cloud, legacy e finale.

VPS12 usa DC02 (`10.10.10.13`) come DNS. DC02 ha come forwarder `10.10.10.14`; AdGuard su VPS14 risponde su DNS 53 TCP/UDP dell'IP VPN. Questa catena è rappresentata in [DNS/AD](../diagrams/dns-active-directory.html).
