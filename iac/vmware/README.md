# VMware lifecycle — manual GUI only

Le VM vengono create manualmente dall'operatore in VMware Workstation Pro.
`vm-definitions.yml` è solo la specifica dichiarativa di nome, OS, risorse,
VMnet8, ISO e IP metadata. IaC non crea VM, VMDK o VMX, non registra VM e non
usa `--apply`.

## Tool rilevati in discovery read-only

| Tool | Risultato | Uso ammesso |
|---|---|---|
| `vmware` | Workstation 26.0.0 | verifica versione; creazione manuale GUI |
| `vmrun` | 1.17.0 | lista VM in esecuzione e stato post-GUI |
| `vmware-vdiskmanager` | disponibile | capability osservata; non usato per creare VMDK |
| `vmware-installer` | disponibile | elenco installazioni |
| `vmware-netcfg` | disponibile, help probe instabile | nessuna modifica di rete |
| `ovftool` | disponibile | non necessario per questo target |

Workstation non espone qui un comando CLI unico e affidabile per creare e
registrare una VM nuova. `vmrun` non è un VM factory; `vmware-vdiskmanager`
può creare dischi, ma questa repository non lo usa. La strategia è quindi:

1. operatore crea le tre VM dalla GUI;
2. operatore collega VMnet8, ISO e risorse secondo `vm-definitions.yml`;
3. operatore lascia le VM spente;
4. `validate-vms` verifica VMX e configurazione in sola lettura;
5. bootstrap OS parte solo dopo validazione PASS.

## Preflight host

`preflight-host` è read-only: rileva Workstation/CLI, verifica VMnet8,
gateway, spazio, ISO e collisioni. I path arrivano da argomenti o variabili;
non sono scritti nella repository. Un WARN mantiene esito non-PASS e un FAIL
blocca il seguito.

```text
iac/vmware/preflight-host \
  --storage-root <VM_STORAGE_ROOT> \
  --ubuntu-desktop-iso <UBUNTU_DESKTOP_ISO> \
  --ubuntu-server-iso <UBUNTU_SERVER_ISO> \
  --windows-server-iso <WINDOWS_SERVER_2022_ISO>
```

## Path VMX privati

Copiare `manual-vm-paths.example.yml` in un file locale escluso da Git e
sostituire i placeholder con i path reali. Usare poi:

```text
iac/vmware/validate-vms --paths-file <PRIVATE_VM_PATHS_FILE>
```

Il validatore non ha modalità `--apply`, non cancella file, non avvia VM e non
modifica VMnet o port-forwarding.
