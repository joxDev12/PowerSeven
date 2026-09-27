# Windows bootstrap e identity configuration

Target: Windows Server 2022 Datacenter Desktop Experience VPS13/DC02. I file
sono template e non vengono eseguiti in questa fase.

- `autounattend.xml`: installazione iniziale e hostname;
- `bootstrap.ps1`: rete underlay, DNS bootstrap, OpenSSH/WinRM e ruoli AD DS/DNS;
- AD CS resta escluso: nessuna evidenza sufficiente nel modello sorgente;
- la promozione del Domain Controller è un'operazione separata e non è inclusa.

Tutte le credenziali sono riferimenti esterni.
