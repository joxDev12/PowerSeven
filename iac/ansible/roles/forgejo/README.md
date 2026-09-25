# forgejo

Scope: fresh Forgejo container/config, PostgreSQL connection and LDAP
settings. Inputs: `git.lab.test`, empty volume and secret refs. Requires:
`docker`, `postgresql`; LDAP/AD availability is a cross-host prerequisite,
not the VPS14 SSSD role. No repository migration.
