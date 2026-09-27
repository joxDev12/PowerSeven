# ad_ds

Scope: AD DS role contract for DC02. The executable local workflow is
`iac/windows/bootstrap.ps1` checkpoint 3/4, with DSRM supplied interactively.
Inputs: domain/admin/DSRM secret refs. Ansible integration remains a future
wrapper around the reviewed PowerShell checkpoints; it must not perform a
second promotion.
