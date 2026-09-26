# PowerSeven dashboard

Live source copied from `/opt/azienda-portal` on VPS14. The service is
`azienda-portal.service`, Gunicorn on `127.0.0.1:5000`, proxied by Nginx for
`login.lab.test`.

Authentication is AD-only through a direct user bind to the `LDAP_URL` target.
The user must be a member of `LDAP_REQUIRED_GROUP`; `displayName`, `mail`,
`userPrincipalName`, and `memberOf` are kept in the signed Flask session.

The live DC02 RootDSE works on LDAP/389. LDAPS/636 currently resets during TLS
negotiation, so the lab overlay LDAP endpoint is used temporarily. The code
keeps certificate validation enabled if `LDAP_URL` is later changed to LDAPS.

PostgreSQL is not imported, configured, or contacted by this application.
`azienda_lab` is retained because it contains non-identity data (`inventario`,
`sedi`, and `ticket`).
