# Windows VPS13/DC02

Target: Windows Server 2022 Datacenter Desktop Experience, `DC02`,
`192.168.214.13/24`, dominio nuovo `LAB.TEST`.

## Workflow eseguibile

`bootstrap.ps1` è un orchestratore a checkpoint, non un installer one-shot.
Senza `-Apply` è read-only; `-Apply` richiede sempre un checkpoint singolo.
Non esegue reboot automaticamente.

```powershell
.\bootstrap.ps1 -Check
.\bootstrap.ps1 -Apply -Checkpoint 1
.\bootstrap.ps1 -Apply -Checkpoint 2 -InterfaceAlias Ethernet
# riavvio manuale dopo il cambio hostname; rieseguire checkpoint 2
.\bootstrap.ps1 -Apply -Checkpoint 3
# se restituisce REBOOT_REQUIRED: riavvio manuale, rieseguire checkpoint 3
.\bootstrap.ps1 -Apply -Checkpoint 4
# riavvio manuale dopo la promozione forest
.\bootstrap.ps1 -Apply -Checkpoint 5
.\bootstrap.ps1 -Apply -Checkpoint 6
.\bootstrap.ps1 -Apply -Checkpoint 7
.\validate-vps13.ps1
```

Checkpoint:

1. verifica OS/Desktop Experience e abilita OpenSSH/PowerShell Remoting;
2. hostname, IP, gateway e DNS bootstrap;
3. feature AD DS e DNS;
4. forest/domain `LAB.TEST` con prompt SecureString DSRM;
5. zona AD-integrated, `_msdcs`, forwarder iniziale `1.1.1.1`/`8.8.8.8` e
   DNS client post-promozione `192.168.214.13`;
6. gruppi automatici e utenti definiti dall'installatore, senza password versionate;
7. record A `lab.test` dal catalogo locale;
8. validation read-only.

`validate-vps13.ps1` verifica hostname, rete, servizi AD DS/DNS, forest/domain,
zone, record, utenti, gruppi e membership. Non verifica né stampa password.

## Dichiarazioni e secret

- `provisioning.psd1`: target VPS13, `LAB.TEST`, forwarder e record DNS;
- `users.psd1`: gruppi PowerSeven e catalogo utenti vuoto;
- `users.local.psd1`: eventuale manifest locale dell'installatore, ignorato da Git;
- `secrets.example.psd1`: riferimenti runtime, senza valori segreti;
- `secrets.psd1`: file locale ignorato da Git, opzionale; in assenza il
  workflow richiede DSRM e password utenti con `Read-Host -AsSecureString`.

AD CS, LDAPS, CA, WireGuard e gli altri host restano fuori scope.
