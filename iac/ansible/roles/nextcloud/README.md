# nextcloud

Scope: fresh Nextcloud container/config, PostgreSQL connection and LDAP
settings. Inputs: `cloud.lab.test`, empty volume and secret refs. Requires:
`docker`, `postgresql`; LDAP/AD availability is a cross-host prerequisite,
not the VPS14 SSSD role. No old data migration.
