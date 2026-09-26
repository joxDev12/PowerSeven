# Cockpit come GUI del kill switch VPS14

## Esito

Cockpit standard è sufficiente per il requisito Start/Stop/Restart/Status: la
pagina Services usa systemd/D-Bus e le unità `powerseven-*.service` risultano
normali servizi. Non serve un plugin custom e OliveTin resta solo fallback.

Cockpit non sostituisce la dashboard PowerSeven. La dashboard è la GUI
principale del laboratorio e resta CORE; Cockpit è la GUI tecnica per systemd,
log e diagnostica.

Cockpit non è installato sulla VPS14 Azure e non è stato installato durante la
discovery.

Riferimenti ufficiali:

- [systemd e servizi in Cockpit](https://docs.cockpit-project.org/cockpit-guide/main/guide/feature-systemd.html)
- [socket activation e porta 9090](https://docs.cockpit-project.org/cockpit-guide/latest/guide/startup.html)
- [indirizzo/porta del socket](https://docs.cockpit-project.org/cockpit-guide/364/guide/listen.html)
- [autenticazione e accesso al server](https://docs.cockpit-project.org/cockpit-guide/main/guide/authentication.html)

## Installazione futura

Solo nella fase locale autorizzata:

1. installare il pacchetto Cockpit dalla sorgente Ubuntu approvata;
2. abilitare `cockpit.socket`, senza avviare un servizio permanente;
3. verificare `https://10.10.10.14:9090` da DC02 `10.10.10.13`;
4. applicare la policy Polkit e il gruppo operatori;
5. installare/renderizzare le unità `iac/service-control/systemd/`;
6. disabilitare le unità native optional dichiarate in `profiles.yml`;
7. abilitare solo `powerseven-core.target`.

Cockpit usa socket activation: il socket resta in ascolto su TCP 9090 e
`cockpit-ws` viene avviato alla connessione; la documentazione indica anche
che il processo web termina dopo inattività. La RAM idle pianificata è quindi
quasi nulla per il processo e circa 20–60 MiB durante una sessione, da misurare
nel rebuild con `systemctl show cockpit.service` e `ps`.

Non pubblicare 9090 su Internet. La regola firewall futura deve consentire
almeno `10.10.10.13 -> 10.10.10.14:9090/tcp`; `10.10.10.101` è opzionale.
Questa regola è documentata soltanto, non applicata.

## Modello systemd

```text
Cockpit Services
    ↓ D-Bus / Polkit
powerseven-app-<name>.service
    ↓ fixed allowlist
powerseven-controller
    ↓
systemd dependencies + docker compose up/stop
    ↓
application containers and host services
```

`powerseven-core.target` avvia WireGuard, `ssh.socket`, Docker/containerd,
AdGuard, `azienda-portal.service`, il health check della dashboard, Nginx e
`cockpit.socket`. PostgreSQL è una dipendenza condivisa, non CORE. Ogni
applicazione:

- dichiara la propria unione di dipendenze;
- usa una unità `Type=oneshot` e health check bounded;
- viene rilevata da systemd/Docker a ogni transizione;
- non usa `Conflicts=` con le altre applicazioni;
- non contiene `ExecStop` per WireGuard, SSH, Docker, Nginx o AdGuard.

Le dipendenze condivise, come PostgreSQL tra Nextcloud/Forgejo, usano il cluster
concreto `postgresql@18-main.service` e restano attive
finché almeno un'applicazione attiva le richiede. Il controller non usa
contatori persistenti: ricalcola l'unione e ferma solo dipendenze allowlistate
non più richieste. Docker resta sempre CORE.

La dashboard non è un controller root. Legge in sola lettura
`/run/powerseven/active-profile`, `services`, `health`, `ram`,
`last-transition` e `last-failure`, più stato systemd read-only quando
disponibile. `powerseven-service` è l’unico writer root e usa allowlist fissa.
Dashboard, Cockpit, systemd, controller e Compose restano piani distinti.

## Least privilege

Creare in futuro il gruppo locale `powerseven-operators`, senza aggiungerlo a
`sudo`, `adm`, `docker` o altri gruppi amministrativi. I file di segreto devono
restare `root`/gruppo applicativo e non devono essere leggibili dal gruppo.

La regola di esempio
[`50-powerseven-operators.rules.example`](../iac/service-control/polkit/50-powerseven-operators.rules.example)
concede soltanto `start`, `stop` e `restart` su:

```text
powerseven-app-nextcloud.service
powerseven-app-forgejo.service
powerseven-profile-stirling.service
powerseven-profile-pterodactyl.service
powerseven-profile-wazuh.service
powerseven-profile-scribble.service
powerseven-stop-all-optional.service
```

Non concede `manage-unit-files`, `reload-daemon`, rete, firewall, Docker
socket o unità arbitrarie. CORE non è nella allowlist: un operatore non può
fermare il percorso amministrativo.

Limite da verificare nel test locale: Cockpit offre anche un terminale con i
privilegi dell'utente. La policy funziona solo se il gruppo non ha sudo e
l'utente non eredita un altro percorso root; il terminale resta una shell
utente non privilegiata, non una shell root. Verificare inoltre accesso ai log,
process list e D-Bus prima di dichiarare la separazione conforme.

## Accesso da DC02

Percorso previsto:

```text
DC02 10.10.10.13 browser
    -> HTTPS 10.10.10.14:9090
    -> cockpit-ws socket activation
    -> systemd / Polkit
    -> PowerSeven profile unit
```

Il client deve usare la rete WireGuard già esistente; non usare l'IP pubblico
Azure e non fare reverse proxy Internet per Cockpit. La porta 9090 è distinta
da Nginx 80/443 per mantenere il confine amministrativo esplicito.

## Validazione minima

Prima dell'accettazione locale:

```text
CORE active after boot
ALL-OFF-OPTIONAL active after boot
WireGuard, ssh.socket, Nginx, dashboard, PostgreSQL, AdGuard and Cockpit socket remain active after every optional action
only one application profile active
start/stop/restart/status visible in Cockpit Services
operators cannot manage arbitrary system units or read application secrets
```

If a profile transition fails, `active-profile` becomes `FAILED`, a failure
timestamp is recorded, CORE remains active, and no retry loop starts optional
services implicitly.

Il validatore statico è `python3 iac/service-control/validate.py`; la prova
runtime richiede il rebuild locale e non è stata eseguita su Azure.
