# Copy to deploy.local.ps1 (git-ignored) and fill in. deploy.ps1 loads it when
# -RokuIp/-Password and $env:ROKU_IP/$env:ROKU_DEV_PASSWORD aren't set.

# The Roku a plain .\scripts\deploy.ps1 installs to, and the developer password
# used for every Roku unless one sets its own.
$LocalRokuIp = '192.168.1.50'
$LocalRokuPassword = 'your-developer-password'

# Every Roku for .\scripts\deploy.ps1 -All. Password is optional per Roku.
$LocalRokus = @(
    @{ Name = 'Living room'; Ip = '192.168.1.50' }
    @{ Name = 'Bedroom'; Ip = '192.168.1.51' }
    # @{ Name = 'Kitchen'; Ip = '192.168.1.52'; Password = 'a-different-password' }
)

# The home Raspberry Pi for .\scripts\pi-deploy.ps1 (an SSH host from ~\.ssh\config,
# or user@address; key login, no password prompt). Default: iptv-pi.
# $LocalPi = 'iptv-pi'

# Household key for V2 backups on the Pi: 64 hex characters (32 random bytes).
# Keep it secret; a new key makes existing backups unreadable.
# $BackupKey = '<64 hex characters>'

# Password for the admin page on the Pi (http://<pi>:8792/admin). Only its hash goes
# to the Pi. Change it here, then run .\scripts\pi-deploy.ps1 -Service backup.
# $AdminPassword = '<a password>'
