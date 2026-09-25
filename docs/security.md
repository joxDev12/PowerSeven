# Sicurezza

TLS usa certificati emessi da `SOC Lab Training CA` per i servizi `lab.test`; sono state consultate solo subject, issuer e date. Chiavi private e materiale CA non sono stati copiati.

Wazuh agent è attivo su VPS12 e DC02, con manager VPS14. I firewall profili Windows sono attivi. Su VPS12 e VPS14 UFW risulta inattivo; VPS14 usa regole nftables/Docker per forwarding e NAT, ma vari listener host sono su tutte le interfacce.

Rischi da esaminare: servizi AD/RDP/WinRM e Nginx esposti anche alla rete cloud, PostgreSQL anche su `10.10.10.14` e porte Wings/Wazuh pubblicate. Non è stata modificata alcuna regola.
