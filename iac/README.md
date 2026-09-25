# Modello IaC locale PowerSeven

Questo catalogo è solo dichiarativo. Non crea VM, non installa pacchetti e non
contiene segreti. La fonte primaria è [`../graph/powerseven.graph.json`](../graph/powerseven.graph.json);
i file YAML sono la proiezione operativa usabile in futuro da renderer VMware,
Ansible, PowerShell e test di accettazione.

## Toolchain proposta

| Area | Scelta | Motivo |
|---|---|---|
| VM lifecycle | script versionati + VMware Workstation Pro `vmrun` | `vmrun` controlla il ciclo di vita delle VM già create; Workstation non offre un provider Terraform/OpenTofu robusto per questo target |
| Immagini Linux | Packer solo dopo il primo rebuild manuale | rende ripetibile il template, ma non serve prima di aver fissato ISO, dischi e rete |
| Bootstrap Ubuntu | autoinstall/cloud-init | hostname, rete, utenti iniziali e pacchetti base |
| Bootstrap Windows | Windows unattend + PowerShell | installazione Server 2022 e configurazione iniziale senza dipendere da un provider VMware |
| Configurazione | Ansible Linux + `ansible.windows`/PowerShell Windows | idempotenza, check mode e un solo catalogo di variabili |
| AD/DNS | PowerShell/Ansible Windows | AD DS richiede ruoli Windows e promozione DC esplicita |
| Servizi | Ansible + Compose/config applicative versionate | separa host, runtime, config e dati |
| Segreti | secret store esterno o file locale escluso dal repository | il grafo contiene solo `secret_required` e riferimenti logici |

OpenTofu/Terraform non è scelto per creare le tre VM: VMware Workstation Pro
non è un target pratico quanto vSphere/ESXi e introdurrebbe un provider o un
workflow fragile. Potrà essere rivalutato se l'host passerà a vSphere/ESXi.

## File

- `inventory/hosts.yml`: tre VM, capacità osservate, OS, IP, software host.
- `inventory/networks.yml`: Internet, VNet Azure di riferimento, overlay
  WireGuard e reti Docker.
- `inventory/services.yml`: servizi, container, porte e datastore applicativi.
- `inventory/dns.yml`: dominio AD, record e catena resolver/forwarder.
- `inventory/storage.yml`: dati persistenti, origine, destinazione e migrazione.
- `inventory/dependencies.yml`: grafo ridotto delle dipendenze e ordine di
  provisioning.

## Regole

1. Aggiornare il grafo dopo ogni discovery o decisione architetturale.
2. Derivare YAML dal grafo; non correggere un inventario divergente a mano.
3. Usare `state: unverified` quando un valore non è stato letto direttamente.
4. Usare solo riferimenti come `REQUIRED_SECRET`; mai password, token o chiavi.
5. Prima del provisioning aggiungere validatori che rifiutino ID mancanti,
   segreti inline, IP duplicati e dipendenze cicliche.

## Stato

Il modello descrive il target locale equivalente alle VPS12/VPS13/VPS14.
Provisioning reale, migrazione dati e installazione tool sono fuori scope.
