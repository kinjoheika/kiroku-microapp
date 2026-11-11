# Kiroku weekly backup: a full copy of the Kiroku database (every table, its rows, its security rules and
# functions) to a dated file. Runs from Windows Task Scheduler (see backup/README.md); can also be run by hand.
#
# Settings come from C:\Kiruko\backups\kiroku-backup.json (made by setup-backup.ps1). The database password
# is NOT in any file here: pg_dump reads it from %APPDATA%\postgresql\pgpass.conf, which only your Windows
# account can open. Backups are kept outside the GitHub folder, so they are never published.

param(
  [string]$ConfigPath = 'C:\Kiruko\backups\kiroku-backup.json'
)
$ErrorActionPreference = 'Stop'

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$folder = $config.BackupFolder
$keep = [int]$config.Keep
$log = Join-Path $folder 'backup.log'
function Write-Log($text) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $text
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Output $line
}

New-Item -ItemType Directory -Force -Path $folder | Out-Null
$file = Join-Path $folder ('kiroku-' + (Get-Date -Format 'yyyy-MM-dd_HHmm') + '.dump')

try {
  # --schema=public: everything Kiroku has (tables, rows, rules, functions, triggers).
  # Logins (Supabase Authentication) are not in it: after a restore into a new project, people are added again.
  & $config.PgDump --host=$($config.Host) --port=$($config.Port) --username=$($config.User) `
      --dbname=$($config.Database) --schema=public --format=custom --no-password --file=$file
  if ($LASTEXITCODE -ne 0) { throw "pg_dump stopped with exit code $LASTEXITCODE" }

  # Check the file can be read back: it lists what a restore would create.
  $items = & $config.PgRestore --list $file
  if ($LASTEXITCODE -ne 0) { throw "the backup file could not be read back" }
  $tables = ($items | Select-String -Pattern ' TABLE DATA public ').Count
  $size = [math]::Round((Get-Item $file).Length / 1KB)
  Write-Log "OK  $file  ($size KB, $tables tables with data)"
}
catch {
  if (Test-Path $file) { Remove-Item -Force $file }
  Write-Log "FAILED  $($_.Exception.Message)"
  exit 1
}

# Keep the newest $keep backups; delete older ones.
Get-ChildItem -Path $folder -Filter 'kiroku-*.dump' | Sort-Object Name -Descending |
  Select-Object -Skip $keep | ForEach-Object {
    Remove-Item -Force $_.FullName
    Write-Log "removed old backup $($_.Name)"
  }
exit 0
