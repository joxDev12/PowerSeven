# Docker

Container attivi: AdGuard, Forgejo, Stirling PDF, Nextcloud (`app`, `cron`, `redis`) e due container Scribble. Le reti dedicate sono `soc-adguard_default`, `soc-forgejo_forgejonet`, `soc-stirling_default`, `soc-cloud_cloudnet` e `pterodactyl_nw`.

La maggior parte dei backend è vincolata a loopback; fanno eccezione AdGuard DNS su `10.10.10.14:53` e Scribble su `10.10.10.14:8081/8082`. Non sono state lette variabili d'ambiente o file compose contenenti segreti.
