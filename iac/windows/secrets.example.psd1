@{
    SchemaVersion = 1
    Administrator = @{
        Source = 'interactive'
        Reference = 'administrator_password'
    }
    DirectoryServicesRestoreMode = @{
        Source = 'interactive'
        Reference = 'dsrm_password'
    }
    UserPasswords = @{
        Source = 'interactive'
        Reference = 'user_passwords'
    }
}
