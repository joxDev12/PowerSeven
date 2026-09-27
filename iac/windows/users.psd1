@{
    SchemaVersion = 1
    GroupDefinitions = @(
        @{
            Name = 'PowerSeven-Team'
            Scope = 'Global'
            Category = 'Security'
            Description = 'PowerSeven student and team access'
        }
        @{
            Name = 'PowerSeven-Tutors'
            Scope = 'Global'
            Category = 'Security'
            Description = 'PowerSeven tutor access'
        }
        @{
            Name = 'PowerSeven-Operators'
            Scope = 'Global'
            Category = 'Security'
            Description = 'PowerSeven operational access; not Domain Admin'
        }
        @{
            Name = 'PowerSeven-Administrators'
            Scope = 'Global'
            Category = 'Security'
            Description = 'Reserved for explicitly approved lab administrators'
        }
    )
    # Installer-specific accounts belong in users.local.psd1, which is ignored by Git.
    Users = @()
}
