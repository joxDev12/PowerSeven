# Linux bootstrap e host configuration

Target: Ubuntu Desktop VPS12 e Ubuntu Server VPS14. Questa directory contiene
solo template e variabili: nessun file viene applicato automaticamente.

## Contratto

- hostname e rete statica underlay sono definiti nei template per VM;
- DNS iniziale è il gateway VMware `192.168.214.2`;
- SSH è installato come superficie di bootstrap, con chiave esterna;
- aggiornamenti e upgrade pacchetti sono disabilitati nei template;
- WireGuard, dominio, Docker e applicazioni arrivano dopo il bootstrap via
  Ansible.

Renderizzare i placeholder (`<...>`/`REQUIRED_SECRET`) in un workspace escluso
da Git prima di un futuro provisioning.
