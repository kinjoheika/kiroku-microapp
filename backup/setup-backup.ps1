# Kiroku backup: one-time setup on this PC. Run it yourself in PowerShell (see backup/README.md):
#   powershell -ExecutionPolicy Bypass -File C:\Kiruko\kiroku-v4-microapp\backup\setup-backup.ps1
# It asks for the database connection details and password (typed here, never shown or sent anywhere),
# saves the password where only your Windows account can read it, makes a weekly Task Scheduler job,
# and runs the first backup.

$ErrorActionPreference = 'Stop'
$folder = 'C:\Kiruko\backups'
$pgBin = 'C:\Program Files\PostgreSQL\17\bin'
if (-not (Test-Path "$pgBin\pg_dump.exe")) { throw "pg_dump not found in $pgBin. Install PostgreSQL 17 command-line tools first." }

Write-Host ''
Write-Host 'Supabase > Connect (top of the dashboard) > Connection String > Method: Session pooler.' -ForegroundColor Cyan
Write-Host 'It looks like: postgresql://postgres.abcdefgh:[YOUR-PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
Write-Host ''
$dbHost = (Read-Host 'Host (the part after @ and before :5432, e.g. aws-0-ap-southeast-1.pooler.supabase.com)').Trim()
$dbUser = (Read-Host 'User (the part after postgresql:// and before the colon, e.g. postgres.abcdefgh)').Trim()
$secure = Read-Host 'Database password (Supabase > Project Settings > Database; it is not shown while you type)' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
if (-not $dbHost -or -not $dbUser -or -not $password) { throw 'Host, user and password are all needed.' }

# Password -> %APPDATA%\postgresql\pgpass.conf (PostgreSQL's own password file, inside your Windows profile).
$pgpassDir = Join-Path $env:APPDATA 'postgresql'
$pgpass = Join-Path $pgpassDir 'pgpass.conf'
New-Item -ItemType Directory -Force -Path $pgpassDir | Out-Null
$escaped = $password.Replace('\', '\\').Replace(':', '\:')
$prefix = "${dbHost}:5432:postgres:${dbUser}:"
$lines = @()
if (Test-Path $pgpass) { $lines = @(Get-Content $pgpass | Where-Object { -not $_.StartsWith($prefix) }) }
$lines += $prefix + $escaped
Set-Content -Path $pgpass -Value $lines -Encoding ASCII
$password = $null; $escaped = $null
# Only this Windows account may read it.
icacls $pgpass /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null

# Settings (no password in here).
New-Item -ItemType Directory -Force -Path $folder | Out-Null
[ordered]@{
  Host = $dbHost; Port = 5432; Database = 'postgres'; User = $dbUser
  BackupFolder = $folder; Keep = 12
  PgDump = "$pgBin\pg_dump.exe"; PgRestore = "$pgBin\pg_restore.exe"
} | ConvertTo-Json | Set-Content -Path "$folder\kiroku-backup.json" -Encoding UTF8

# Weekly job: Mondays 10:00. If the PC is off then, it runs at the next start.
$script = Join-Path $PSScriptRoot 'backup.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 10:00
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName 'Kiroku weekly backup' -Action $action -Trigger $trigger -Settings $settings `
  -Description 'Copies the Kiroku database to C:\Kiruko\backups (see backup/README.md).' -Force | Out-Null
Write-Host 'Weekly job made: Task Scheduler > "Kiroku weekly backup" (Mondays 10:00).' -ForegroundColor Green

Write-Host 'Running the first backup now...'
& $script
if ($LASTEXITCODE -eq 0) { Write-Host 'Done. Backups are in C:\Kiruko\backups' -ForegroundColor Green }
else { Write-Host 'The first backup failed: see C:\Kiruko\backups\backup.log' -ForegroundColor Red }
