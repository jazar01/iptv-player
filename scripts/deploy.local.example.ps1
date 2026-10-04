# Copy to deploy.local.ps1 (git-ignored) and fill in. deploy.ps1 loads it when
# -RokuIp/-Password and $env:ROKU_IP/$env:ROKU_DEV_PASSWORD aren't set.
$LocalRokuIp = '192.168.1.50'
$LocalRokuPassword = 'your-developer-password'
