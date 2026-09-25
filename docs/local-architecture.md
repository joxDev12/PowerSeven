# Architettura locale PowerSeven

Target: laboratorio nuovo su VMware Workstation Pro, tre VM, nessuna
dipendenza Azure e nessun dato applicativo precedente.

## Requisiti host astratti

| Risorsa | Requisito di laboratorio |
|---|---|
| Hypervisor | VMware Workstation Pro |
| CPU | Minimo 8 vCPU allocabili al laboratorio; lasciare margine all'host |
| RAM | Minimo 10 GiB per le VM; profilo raccomandato 11 GiB complessivi |
| Storage | Minimo 230 GiB thin; profilo raccomandato 320 GiB thin |
| Storage root | `<VM_STORAGE_ROOT>` configurabile, senza percorsi host hardcoded |
| Rete | Una rete VMware underlay non sovrapposta alle reti locali esistenti |

Questi sono requisiti del laboratorio, non una descrizione del computer host.
Prima dell'implementazione l'operatore deve verificare capacità, storage e CIDR.

## Rete

### Underlay VMware

Target approvato: usare VMnet8 NAT:

| Elemento | Valore |
|---|---|
| CIDR | `192.168.214.0/24` |
| Host VMnet8 | `192.168.214.1` |
| Gateway/NAT VMware | `192.168.214.2` |
| DHCP osservato | `192.168.214.128-254` |
| VPS12 | `192.168.214.12` |
| VPS13 | `192.168.214.13` |
| VPS14 | `192.168.214.14` |

Gli IP `.12-.14` sono fuori dal range DHCP osservato. Configurare statici o
reservation, mai lease casuali. Internet passa dal NAT VMware.

Prima dell'implementazione verificare che underlay, overlay WireGuard, LAN,
VMnet e bridge container non abbiano CIDR sovrapposti. Nessuna rete host viene
assunta o modificata da questo modello.

### Overlay WireGuard

Target approvato; il tunnel resta separato dall'underlay:

| Peer | IP |
|---|---|
| VPS12 | `10.10.10.12/32` |
| VPS13 | `10.10.10.13/32` |
| VPS14 hub | `10.10.10.14/24` |
| giorgio, peppe, marco, monia, rocca, chiara, simone | `10.10.10.101-.107/32` |

Underlay trasporta WireGuard; l'overlay è il percorso VPN per amministrazione e
servizi applicativi. DNS/AD infrastrutturale resta sull'underlay
`192.168.214.13`/`192.168.214.14` anche dopo il bootstrap.

### Piano DNS definitivo

Il trasporto infrastrutturale DNS/AD usa sempre l'underlay VMware:

```text
VPS12/VPS14 -> DC02 DNS 192.168.214.13
DC02 -> AdGuard 192.168.214.14
```

I record applicativi `lab.test` puntano invece all'indirizzo del servizio sul
WireGuard overlay: `10.10.10.14`. Questo vale per `cloud`, `git`, `pdf`,
`login`, `panel`, `wazuh`, `wings`, `adguard`, `scribble` e `scribble-2`.
Il record infrastrutturale `dc02.lab.test` punta a `192.168.214.13`.

Questa distinzione evita di usare l'overlay per il bootstrap AD/DNS e mantiene
gli endpoint applicativi raggiungibili attraverso il percorso VPN previsto.

### Accesso esterno UDP 51820

Design, non configurato:

1. Client esterno raggiunge endpoint host/upstream UDP `51820`.
2. NAT inoltra a `192.168.214.14:51820`.
3. VPS14 termina WireGuard.

Scegliere un solo owner per il port-forward VMware NAT oppure per un router
dedicato. Prima dell'implementazione verificare l'assenza di conflitti sul
listener UDP `51820`; non configurare ora.

## VM e dimensionamento

Dimensionamento del laboratorio. Tutte le VM possono partire insieme; VPS14 ha
priorità RAM. I dischi sono thin-provisioned sotto `<VM_STORAGE_ROOT>/PowerSeven`
da creare solo nella fase di implementazione.

| VM | Minimum | Recommended lab profile | Motivo |
|---|---:|---:|---|
| VPS13 / DC02 | 2 vCPU, 3 GiB RAM, 60 GiB | 2 vCPU, 3 GiB, 80 GiB | AD DS, DNS, Kerberos, LDAP, RDP |
| VPS14 / soc-server | 4 vCPU, 5 GiB RAM, 120 GiB | 4 vCPU, 6 GiB, 160 GiB | Docker, Wazuh, DB, Nginx e app |
| VPS12 / soc-desktop | 2 vCPU, 2 GiB RAM, 50 GiB | 2 vCPU, 2 GiB, 80 GiB | Ubuntu Desktop, XFCE, XRDP, SSSD |
| Totale | 8 vCPU, 10 GiB, 230 GiB | 8 vCPU, 11 GiB, 320 GiB | lascia CPU e RAM all'host |

Il profilo raccomandato assegna 2+4+5 GiB = 11 GiB alle VM. Verificare sempre
che l'host disponga di margine sufficiente; se la memoria è stretta, fermare
`soc-desktop` durante i test pesanti.

## Servizi e confini

- VPS13: nuovo forest/domain `LAB.TEST`, DNS autoritativo, Kerberos, LDAP/LDAPS,
  Global Catalog, Windows Firewall, RDP, OpenSSH, Wazuh Agent.
- VPS14: WireGuard hub, Docker, database vuoti, AdGuard, Wazuh, Nginx, CA
  nuova, applicazioni e Pterodactyl. Nessun vecchio volume.
- VPS12: Ubuntu Desktop, WireGuard peer, SSSD/Kerberos, XFCE, XRDP, SSH,
  Wazuh Agent.

Regola firewall iniziale: underlay solo tra tre VM e servizi necessari; SSH,
RDP e XRDP via WireGuard dopo bootstrap; UDP 51820 unico ingresso esterno
eventualmente pubblicato; backend applicativi su loopback/container network.

## Decisione

VMnet8 NAT comune è il target approvato. Non serve replicare le tre VNet Azure.
La rete è fissata a `192.168.214.0/24`; la configurazione reale resta fuori
scope di questa fase.
