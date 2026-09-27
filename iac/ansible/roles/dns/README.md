# dns

Scope: AD-integrated DNS zones, records and forwarder transition. The
executable local DC02 workflow is `iac/windows/bootstrap.ps1` checkpoint 5/7;
its declaration mirrors `iac/inventory/dns.yml`. Initial forwarders are
`1.1.1.1` and `8.8.8.8`; final AdGuard transition remains a later VPS14
phase.
Requires: `ad_ds`.
