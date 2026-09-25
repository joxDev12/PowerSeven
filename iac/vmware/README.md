# VMware lifecycle

Target: VMware Workstation Pro. `vm-definitions.yml` descrive tre VM, NIC
VMnet8, CPU/RAM/disco, ISO e `<VM_STORAGE_ROOT>` senza creare file VMX o VM.

Un renderer futuro potrà generare VMX e usare `vmrun` in una fase separata.
OpenTofu/Terraform non è assunto: Workstation Pro non offre qui un provider
robusto quanto vSphere/ESXi.
