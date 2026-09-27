# common_windows

Scope: common Windows identity, time, locale and fact policy after bootstrap.
The local base checkpoint is implemented in `iac/windows/bootstrap.ps1`; this
role remains the future Ansible integration point. Inputs: hostname/domain
variables. Requires: `openssh_windows`.
