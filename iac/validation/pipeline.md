# Dry-run pipeline

Pipeline prevista, tutta read-only. La creazione delle VM è manuale via GUI;
questa repository non contiene un percorso `apply` per il lifecycle VMware:

1. `iac/validation/preflight` — YAML/JSON, scope, IP/CIDR, secret, dipendenze,
   DNS, porte e risorse.
2. VM definition validation — controllo statico di `vm-definitions.yml`, poi
   `iac/vmware/validate-vms` dopo la creazione manuale; tre VM, VMnet8, ISO e
   `<VM_STORAGE_ROOT>`.
3. OS bootstrap validation — controllo template Linux/Windows e placeholder;
   nessuna ISO viene montata.
4. Ansible syntax/check — futuro `ansible-playbook --syntax-check` e poi
   `--check`; oggi i role sono contratti senza task.
5. Compose validation — futuro `docker compose config` con `.env` privato;
   nessun pull o start.
6. Acceptance plan — generazione dei test da
   `docs/local-acceptance-tests.md`, con WG-03 marcato cutover.
