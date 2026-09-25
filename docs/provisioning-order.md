# Ordine di provisioning locale

Ordine derivato da [dependencies.yml](../iac/inventory/dependencies.yml).
Creazione VM e bootstrap OS sono parallelizzabili; servizi hanno ordine
esplicito. Tutto parte vuoto.

## PHASE 0 — preparazione host VMware

Obiettivo: predisporre solo prerequisiti host.

- verificare Workstation, ISO, spazio `<VM_STORAGE_ROOT>` e collisioni CIDR;
- usare il target approvato VMnet8 NAT `192.168.214.0/24`;
- assegnare `.12`, `.13`, `.14` fuori DHCP;
- decidere owner UDP `51820` senza modificare ancora il sistema;
- definire secret refs locali.

Successo: rete e layout dichiarati; nessuna VM necessaria.

## PHASE 1 — creazione manuale delle tre VM

Creare manualmente in parallelo VPS12, VPS13, VPS14 dalla GUI VMware
Workstation Pro, con risorse da [local-architecture.md](local-architecture.md),
una NIC VMnet8 NAT, ISO e dischi nuovi. Verificare poi con
`iac/vmware/validate-vms`. L'IaC non genera VMX/VMDK e non registra VM. Non
creare snapshot.

Rollback fase: rimuovere manualmente solo VM appena create, se ancora vuote e
non usate; nessun comando IaC esegue questa operazione.

## PHASE 2 — bootstrap OS

Installare in parallelo Ubuntu Desktop, Windows Server 2022 e Ubuntu Server.
Impostare hostname, account tecnici, SSH/OpenSSH dove previsto, timezone e
updates secondo policy futura. DNS temporaneo: `192.168.214.2`.

Rollback fase: reinstallare la singola VM prima della configurazione servizi.

## PHASE 3 — rete underlay

Impostare statici:

- VPS12 `192.168.214.12/24`;
- VPS13 `192.168.214.13/24`;
- VPS14 `192.168.214.14/24`;
- gateway `192.168.214.2`;
- resolver temporaneo `192.168.214.2`.

Test: ping tra VM, risoluzione Internet temporanea, route e ascolti locali.

## PHASE 4 — DC02, AD e DNS bootstrap

Installare AD DS e DNS su VPS13. Creare nuovo forest/domain `LAB.TEST`,
Kerberos, LDAP, Global Catalog, gruppi e utenti minimi. Non installare AD CS:
documentazione esistente non prova che fosse presente.

DNS iniziale:

```text
DC02 authoritative zone: lab.test
DC02 temporary forwarder: 192.168.214.2
VPS14 temporary resolver: 192.168.214.2
VPS12 temporary resolver: 192.168.214.2
```

Il trasporto DNS/AD resta underlay: dopo il bootstrap VPS12/VPS14 usano
`192.168.214.13` e DC02 inoltra a AdGuard `192.168.214.14`. I record
applicativi `lab.test` puntano invece all'overlay `10.10.10.14`.

Test: `Get-ADDomain`, zone AD, record `dc02`, Kerberos ticket e query esterna.

Rollback fase: rimuovere solo il nuovo dominio dalla VM locale; Azure non è
coinvolto.

## PHASE 5 — VPS14 base e AdGuard

Configurare VPS14 con resolver temporaneo. Installare Docker, AdGuard e
WireGuard prerequisites. Avviare AdGuard con nuova configurazione vuota su
`192.168.214.14:53` sull'underlay; i record applicativi continueranno a
puntare a `10.10.10.14` sull'overlay.

Non rendere ancora DC02 dipendente da AdGuard.

Test: query DNS locale verso AdGuard, health endpoint, reachability dal VPS14.

## PHASE 6 — switch DNS finale

Solo dopo health check AdGuard:

1. cambiare forwarder DC02 da `192.168.214.2` a `192.168.214.14`;
2. verificare query Internet da DC02;
3. impostare VPS12/VPS14 resolver primario su DC02 `192.168.214.13`;
4. mantenere record AD locali su DC02;
5. testare `lab.test`, `_msdcs.lab.test` e record applicativi.

Questo spezza il ciclo: DC02 nasce con forwarder temporaneo; AdGuard nasce
senza dipendere da DC02; il forwarder finale viene cambiato dopo.

## PHASE 7 — WireGuard

Configurare prima hub VPS14, poi solo peer VM VPS12/VPS13. Usare
nuove chiavi. Nome unit non assunto: verificare se l'installazione usa
`wg-quick@wg-final` o altro prima di automatizzare.

Test: handshake, ping overlay, route tra peer, UDP `51820`. Non cambiare né
collegare il client WireGuard host `.101` durante questa fase; WG-03 è un test
di cutover finale separato.

## PHASE 8 — identità avanzata e certificati

Creare nuova CA lab su VPS14 o location dichiarata, certificati Nginx e LDAPS,
trust store su VPS12/VPS13. Abilitare LDAPS dopo certificato valido.

Test: `openssl s_client`, bind LDAP/LDAPS, subject/SAN e trust.

## PHASE 9 — database e runtime

Installare PostgreSQL, MariaDB e Redis vuoti. Creare solo database, ruoli,
grant e password referenziate. Avviare reti Docker e volumi vuoti.

Test: listener locali, login con secret ref, database attesi, nessun restore.

## PHASE 10 — applicazioni

Installare/configurare nuovi:

1. Nextcloud;
2. Forgejo;
3. Stirling PDF;
4. azienda-portal;
5. Scribble;
6. Pterodactyl Panel su MariaDB.

Configurare LDAP/LDAPS dove previsto. Dati applicativi restano vuoti.

## PHASE 11 — Pterodactyl runtime

Ordine senza ciclo:

1. Panel e schema DB;
2. configurazione Wings usando token del nuovo Panel;
3. avvio Wings;
4. configurazione `pteroq` usando Panel/DB;
5. health check Panel, queue e daemon.

Panel non richiede Wings per essere installato. Wings e `pteroq` richiedono la
configurazione del Panel, ma questa è dipendenza di configurazione/provisioning,
non ciclo runtime.

## PHASE 12 — Nginx e firewall

Configurare virtual host, nuovi certificati, DNS names e firewall. Pubblicare
solo proxy e porte richieste. Backend restano loopback o reti Docker.

Test: ogni `*.lab.test`, status code atteso, certificato e policy firewall.

## PHASE 13 — Wazuh

Installare Manager, Indexer e Dashboard con indici vuoti. Collegare agenti
VPS12 e DC02 dopo WireGuard e DNS funzionanti.

Test: agenti online, evento nuovo visibile, Dashboard raggiungibile via Nginx.

## PHASE 14 — VPS12

Configurare Ubuntu Desktop, XFCE/XRDP, SSSD/Kerberos, domain join e policy
gruppi. Abilitare SSH e Wazuh Agent.

Test: login dominio via XRDP, accesso gruppo autorizzato, ticket Kerberos,
risoluzione DNS e telemetria Wazuh.

## PHASE 15 — accettazione

Eseguire [local-acceptance-tests.md](local-acceptance-tests.md). Se fallisce,
correggere solo fase responsabile; non fare rollback globale e non toccare
Azure.
