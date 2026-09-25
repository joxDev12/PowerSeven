# Accesso remoto

Il percorso previsto è [documentato nel diagramma](../diagrams/remote-access-sequence.html): PC → WireGuard VPS14 → XRDP VPS12 → DNS/Kerberos AD su DC02.

VPS12 usa XRDP TCP 3389 con `security_layer=negotiate`, cifratura alta e `xrdp-sesman` locale su 3350; `lightdm`, `xfce4-session`, Xorg XRDP e SSSD erano attivi. Il join `lab.test` è `kerberos-member`; la policy ammette `SOC-Desktop-Users@lab.test`.

DC02 espone RDP TCP 3389 e OpenSSH TCP 22. Usare sempre gli indirizzi VPN, non la rete cloud `172.16.0.0/24`.
