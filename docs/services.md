# Servizi VPS14

| DNS | Backend verificato | Pubblicazione |
|---|---|---|
| `cloud.lab.test` | Nextcloud Docker `127.0.0.1:8083` | Nginx TLS |
| `git.lab.test` | Forgejo Docker `127.0.0.1:3001` | Nginx TLS |
| `pdf.lab.test` | Stirling PDF Docker `127.0.0.1:8084` | Nginx TLS |
| `adguard.lab.test` | AdGuard Docker `127.0.0.1:3002` | Nginx TLS |
| `panel.lab.test` | Pterodactyl locale | Nginx TLS |
| `wazuh.lab.test` | Dashboard `127.0.0.1:8443` | Nginx TLS |
| `wings.lab.test` | Wings `127.0.0.1:8080` | Nginx TLS |
| `login.lab.test` | portale/SSO locale | Nginx TLS |
| `scribble*.lab.test` | due container, `10.10.10.14:8081/8082` | Nginx TLS |

Nginx ascolta su 80/443. Wazuh Manager espone 1514/1515 e API 55000; Wings espone SFTP 2022. AdGuard pubblica DNS TCP/UDP 53 sull'IP VPN. Vedere [diagramma servizi](../diagrams/vps14-services.html).
