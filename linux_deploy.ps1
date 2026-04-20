param(
    [Parameter(Mandatory = $true)]
    [string]$PublishFolder,

    [Parameter(Mandatory = $true)]
    [string]$RemoteHost,

    [Parameter(Mandatory = $true)]
    [string]$RemoteUser,

    [Parameter(Mandatory = $true)]
    [string]$RemoteAppDir,

    [Parameter(Mandatory = $true)]
    [string]$AppServiceName,

    [string]$RemoteTempDir = "/tmp",
    [string]$RemoteBackupDir = "/opt/app_backups",
    [string]$RemoteLogDir = "/opt/app_deploy_logs",
    [string]$NginxServiceName = "nginx",
    [int]$Port = 22,
    [string]$SshKeyPath = "",
    [bool]$UseSudo = $true,
    [string]$LocalLogDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.IO.Compression

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Escape-BashSingleQuoted([string]$Value) {
    $replacement = "'" + '"' + "'" + '"' + "'"
    return $Value.Replace("'", $replacement)
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Assert-CommandExists([string]$CommandName) {
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Gerekli komut bulunamadı: $CommandName"
    }
}

function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $baseResolved = (Resolve-Path $BasePath).Path
    $targetResolved = (Resolve-Path $TargetPath).Path

    if (-not $baseResolved.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseResolved += [System.IO.Path]::DirectorySeparatorChar
    }

    $baseUri = New-Object System.Uri($baseResolved)
    $targetUri = New-Object System.Uri($targetResolved)
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)

    return [System.Uri]::UnescapeDataString($relativeUri.ToString())
}

function New-NormalizedZipFromFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceFolder,

        [Parameter(Mandatory = $true)]
        [string]$DestinationZip
    )

    $sourceFullPath = (Resolve-Path $SourceFolder).Path

    if (Test-Path $DestinationZip) {
        Remove-Item $DestinationZip -Force
    }

    $destinationDir = Split-Path $DestinationZip -Parent
    if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
        New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    }

    $fileStream = [System.IO.File]::Open($DestinationZip, [System.IO.FileMode]::Create)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive(
            $fileStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )

        try {
            $files = Get-ChildItem -LiteralPath $sourceFullPath -Recurse -Force -File

            foreach ($file in $files) {
                $relativePath = Get-RelativePathCompat -BasePath $sourceFullPath -TargetPath $file.FullName
                $zipEntryPath = $relativePath -replace '\\', '/'

                $entry = $zip.CreateEntry($zipEntryPath, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()

                try {
                    $inputStream = [System.IO.File]::OpenRead($file.FullName)
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $inputStream.Dispose()
                    }
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

Assert-CommandExists "ssh"
Assert-CommandExists "scp"

if (-not (Test-Path $PublishFolder -PathType Container)) {
    throw "PublishFolder bulunamadı: $PublishFolder"
}

if (-not [string]::IsNullOrWhiteSpace($SshKeyPath)) {
    if (-not (Test-Path $SshKeyPath -PathType Leaf)) {
        throw "SshKeyPath bulunamadı: $SshKeyPath"
    }
}

$publishFolderResolved = (Resolve-Path $PublishFolder).Path
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$appName = Split-Path $RemoteAppDir -Leaf

if ([string]::IsNullOrWhiteSpace($appName)) {
    throw "RemoteAppDir geçersiz görünüyor: $RemoteAppDir"
}

if ([string]::IsNullOrWhiteSpace($LocalLogDir)) {
    $LocalLogDir = Join-Path $PSScriptRoot "deploy-logs"
}

New-Item -ItemType Directory -Force -Path $LocalLogDir | Out-Null

$packageDir = Join-Path $env:TEMP "aspnet_deploy_packages"
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

$localZip = Join-Path $packageDir ("{0}_{1}.zip" -f $appName, $timestamp)
$localHelper = Join-Path $packageDir ("deploy_remote_{0}_{1}.sh" -f $appName, $timestamp)
$localLog = Join-Path $LocalLogDir ("deploy_{0}_{1}.log" -f $appName, $timestamp)

$remoteZipPath = "{0}/{1}_{2}.zip" -f $RemoteTempDir.TrimEnd('/'), $appName, $timestamp
$remoteHelperPath = "{0}/deploy_{1}_{2}.sh" -f $RemoteTempDir.TrimEnd('/'), $appName, $timestamp
$remoteLogPath = "{0}/{1}_deploy_{2}.log" -f $RemoteLogDir.TrimEnd('/'), $appName, $timestamp
$useSudoValue = if ($UseSudo) { "1" } else { "0" }

$sshTarget = "$RemoteUser@$RemoteHost"

$sshArgs = @("-p", "$Port")
$scpArgs = @("-P", "$Port")

if (-not [string]::IsNullOrWhiteSpace($SshKeyPath)) {
    $resolvedKey = (Resolve-Path $SshKeyPath).Path
    $sshArgs += @("-i", $resolvedKey)
    $scpArgs += @("-i", $resolvedKey)
}

$publishItems = @(Get-ChildItem -Force -Path $publishFolderResolved)
if ($publishItems.Count -eq 0) {
    throw "Publish klasörü boş: $publishFolderResolved"
}

$escapedRemoteZipPath = Escape-BashSingleQuoted $remoteZipPath
$escapedRemoteAppDir = Escape-BashSingleQuoted $RemoteAppDir
$escapedRemoteBackupDir = Escape-BashSingleQuoted $RemoteBackupDir
$escapedRemoteLogDir = Escape-BashSingleQuoted $RemoteLogDir
$escapedRemoteLogPath = Escape-BashSingleQuoted $remoteLogPath
$escapedAppServiceName = Escape-BashSingleQuoted $AppServiceName
$escapedNginxServiceName = Escape-BashSingleQuoted $NginxServiceName
$escapedRemoteHelperPath = Escape-BashSingleQuoted $remoteHelperPath
$escapedUseSudoValue = Escape-BashSingleQuoted $useSudoValue
$escapedRemoteTempDir = Escape-BashSingleQuoted $RemoteTempDir

$remoteScriptTemplate = @'
#!/usr/bin/env bash
set -euo pipefail
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

REMOTE_ZIP='__REMOTE_ZIP__'
APP_DIR='__APP_DIR__'
BACKUP_DIR='__BACKUP_DIR__'
LOG_DIR='__LOG_DIR__'
LOG_FILE='__LOG_FILE__'
APP_SERVICE='__APP_SERVICE__'
NGINX_SERVICE='__NGINX_SERVICE__'
REMOTE_HELPER='__REMOTE_HELPER__'
USE_SUDO='__USE_SUDO__'

LOCAL_UID="$(id -u)"
LOCAL_GID="$(id -g)"

run() {
  if [ "$USE_SUDO" = "1" ]; then
    sudo "$@"
  else
    "$@"
  fi
}

prepare_log_target() {
  if [ "$USE_SUDO" = "1" ]; then
    sudo mkdir -p "$LOG_DIR"
    sudo touch "$LOG_FILE"
    sudo chown "$(id -u):$(id -g)" "$LOG_FILE" || true
    sudo chmod 664 "$LOG_FILE" || true
  else
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
  fi
}

prepare_log_target
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ROLLBACK_DONE=0
SERVICES_STOPPED=0
BACKUP_CREATED=0
TMP_ROOT=""
EXTRACT_DIR=""
BACKUP_ZIP=""
RESTORE_ROOT=""
PARENT_DIR=""
BASE_DIR=""
PERM_MANIFEST=""
APP_DIR_UID=""
APP_DIR_GID=""
APP_DIR_MODE=""
PRIMARY_EXECUTABLE=""

rollback() {
  if [ "$ROLLBACK_DONE" = "1" ]; then
    return
  fi

  ROLLBACK_DONE=1
  set +e

  log "Rollback started..."

  if [ "$BACKUP_CREATED" = "1" ] && [ -n "$BACKUP_ZIP" ] && [ -f "$BACKUP_ZIP" ]; then
    log "Trying restore from backup: $BACKUP_ZIP"

    RESTORE_ROOT="$(mktemp -d "/tmp/${BASE_DIR}_restore_XXXXXX")"

    if [ -d "$APP_DIR" ]; then
      run find "$APP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    else
      run mkdir -p "$APP_DIR"
    fi

    set +e
    run unzip -oq "$BACKUP_ZIP" -d "$RESTORE_ROOT"
    ROLLBACK_UNZIP_EXIT=$?
    set -e

    if [ "$USE_SUDO" = "1" ]; then
      run chown -R "$LOCAL_UID:$LOCAL_GID" "$RESTORE_ROOT" || true
    fi

    if [ "$ROLLBACK_UNZIP_EXIT" -gt 1 ]; then
      log "Rollback unzip failed. exit code=$ROLLBACK_UNZIP_EXIT"
      exit "$ROLLBACK_UNZIP_EXIT"
    elif [ "$ROLLBACK_UNZIP_EXIT" -eq 1 ]; then
      log "Rollback unzip completed with warnings. Continuing."
    fi

    if [ -d "$RESTORE_ROOT/$BASE_DIR" ]; then
      run cp -a "$RESTORE_ROOT/$BASE_DIR"/. "$APP_DIR"/
      log "Application folder restored successfully."
    else
      log "WARNING: Expected restore folder not found: $RESTORE_ROOT/$BASE_DIR"
    fi

    if [ -n "$APP_DIR_UID" ] && [ -n "$APP_DIR_GID" ]; then
      run chown -R "$APP_DIR_UID:$APP_DIR_GID" "$APP_DIR" || true
    fi

    if [ -n "$APP_DIR_MODE" ]; then
      run chmod "$APP_DIR_MODE" "$APP_DIR" || true
    fi

    if [ -f "$PRIMARY_EXECUTABLE" ]; then
      run chmod +x "$PRIMARY_EXECUTABLE" || true
    fi

    run find "$APP_DIR" -type f -name '*.sh' -exec chmod +x {} + || true
    run rm -rf "$RESTORE_ROOT" || true
  else
    log "No usable backup found for rollback."
  fi

  if [ "$SERVICES_STOPPED" = "1" ]; then
    log "Restarting services during rollback..."
    run systemctl start "$APP_SERVICE" || true
    run systemctl start "$NGINX_SERVICE" || true
  fi

  if [ -n "$TMP_ROOT" ]; then
    run rm -rf "$TMP_ROOT" || true
  fi

  run rm -f "$REMOTE_ZIP" || true
  run rm -f "$REMOTE_HELPER" || true

  log "Rollback completed."
}

on_error() {
  local exit_code=$?
  local line_no=${1:-unknown}
  log "ERROR: Deploy failed. Line=$line_no ExitCode=$exit_code"
  rollback
  exit $exit_code
}

trap 'on_error $LINENO' ERR

for cmd in unzip zip systemctl cp find rm mkdir tee date basename dirname stat chmod chown mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || { log "Required command not found: $cmd"; exit 1; }
done

if [ "$USE_SUDO" = "1" ]; then
  command -v sudo >/dev/null 2>&1 || { log "Required command not found: sudo"; exit 1; }
fi

log "Deploy started."
log "APP_DIR=$APP_DIR"
log "REMOTE_ZIP=$REMOTE_ZIP"
log "LOG_FILE=$LOG_FILE"

log "[1/7] Preparing directories..."
run mkdir -p "$APP_DIR"
run mkdir -p "$BACKUP_DIR"

BASE_DIR="$(basename "$APP_DIR")"
PARENT_DIR="$(dirname "$APP_DIR")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
TMP_ROOT="$(mktemp -d "/tmp/${BASE_DIR}_deploy_${TIMESTAMP}_XXXXXX")"
EXTRACT_DIR="$TMP_ROOT/extracted"
BACKUP_ZIP="$BACKUP_DIR/${BASE_DIR}_${TIMESTAMP}.zip"
PERM_MANIFEST="$TMP_ROOT/permissions.tsv"
PRIMARY_EXECUTABLE="$APP_DIR/$BASE_DIR"

APP_DIR_UID="$(run stat -c '%u' "$APP_DIR")"
APP_DIR_GID="$(run stat -c '%g' "$APP_DIR")"
APP_DIR_MODE="$(run stat -c '%a' "$APP_DIR")"

log "BACKUP_ZIP=$BACKUP_ZIP"

mkdir -p "$EXTRACT_DIR"
chmod 700 "$TMP_ROOT"

log "[1b/7] Capturing current ownership and permissions..."
: > "$PERM_MANIFEST"
run find "$APP_DIR" \( -type f -o -type d \) -printf '%P\t%m\t%U\t%G\n' > "$PERM_MANIFEST"

log "[2/7] Extracting new package..."
set +e
run unzip -oq "$REMOTE_ZIP" -d "$EXTRACT_DIR"
UNZIP_EXIT=$?
set -e

if [ "$USE_SUDO" = "1" ]; then
  run chown -R "$LOCAL_UID:$LOCAL_GID" "$TMP_ROOT" || true
fi

if [ "$UNZIP_EXIT" -gt 1 ]; then
  log "Package extraction failed. unzip exit code=$UNZIP_EXIT"
  exit "$UNZIP_EXIT"
elif [ "$UNZIP_EXIT" -eq 1 ]; then
  log "Package extracted with warnings. Continuing."
fi

if [ -z "$(find "$EXTRACT_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  log "Extracted package appears to be empty."
  exit 1
fi

log "[3/7] Stopping services..."
run systemctl stop "$NGINX_SERVICE"
run systemctl stop "$APP_SERVICE"
SERVICES_STOPPED=1

log "[4/7] Creating backup zip..."
(
  cd "$PARENT_DIR"
  run zip -qr "$BACKUP_ZIP" "$BASE_DIR"
)
BACKUP_CREATED=1
log "Backup created: $BACKUP_ZIP"

log "[5/7] Cleaning existing application files..."
run find "$APP_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

log "[6/7] Copying new files to application directory..."
run cp -a "$EXTRACT_DIR"/. "$APP_DIR"/

log "[6a/7] Applying default ownership..."
run chown -R "$APP_DIR_UID:$APP_DIR_GID" "$APP_DIR"
run chmod "$APP_DIR_MODE" "$APP_DIR"

log "[6b/7] Applying safe default permissions..."
run find "$APP_DIR" -type d -exec chmod 755 {} +
run find "$APP_DIR" -type f -exec chmod 644 {} +

if [ -f "$PERM_MANIFEST" ]; then
  log "[6c/7] Restoring permissions from previous release..."
  while IFS=$'\t' read -r rel_path mode uid gid; do
    if [ -z "$rel_path" ]; then
      continue
    fi

    target="$APP_DIR/$rel_path"
    if [ -e "$target" ]; then
      run chown "$uid:$gid" "$target"
      run chmod "$mode" "$target"
    fi
  done < "$PERM_MANIFEST"
fi

if [ -f "$PRIMARY_EXECUTABLE" ]; then
  log "[6d/7] Ensuring primary executable permission..."
  run chmod +x "$PRIMARY_EXECUTABLE"
fi

log "[6e/7] Ensuring shell scripts are executable..."
run find "$APP_DIR" -type f -name '*.sh' -exec chmod +x {} +

log "[7/7] Starting services..."
run systemctl start "$APP_SERVICE"
run systemctl start "$NGINX_SERVICE"
SERVICES_STOPPED=0

log "Cleaning temporary files..."
run rm -rf "$TMP_ROOT"
run rm -f "$REMOTE_ZIP"
run rm -f "$REMOTE_HELPER"

log "Deploy completed successfully."
log "Remote log file: $LOG_FILE"
log "Backup file: $BACKUP_ZIP"
'@

$remoteScript = $remoteScriptTemplate
$remoteScript = $remoteScript.Replace('__REMOTE_ZIP__', $escapedRemoteZipPath)
$remoteScript = $remoteScript.Replace('__APP_DIR__', $escapedRemoteAppDir)
$remoteScript = $remoteScript.Replace('__BACKUP_DIR__', $escapedRemoteBackupDir)
$remoteScript = $remoteScript.Replace('__LOG_DIR__', $escapedRemoteLogDir)
$remoteScript = $remoteScript.Replace('__LOG_FILE__', $escapedRemoteLogPath)
$remoteScript = $remoteScript.Replace('__APP_SERVICE__', $escapedAppServiceName)
$remoteScript = $remoteScript.Replace('__NGINX_SERVICE__', $escapedNginxServiceName)
$remoteScript = $remoteScript.Replace('__REMOTE_HELPER__', $escapedRemoteHelperPath)
$remoteScript = $remoteScript.Replace('__USE_SUDO__', $escapedUseSudoValue)

$transcriptStarted = $false

try {
    Start-Transcript -Path $localLog -Force | Out-Null
    $transcriptStarted = $true

    Write-Step "Publish klasörü zipleniyor: $localZip"
    New-NormalizedZipFromFolder -SourceFolder $publishFolderResolved -DestinationZip $localZip

    Write-Step "Remote helper script oluşturuluyor"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $remoteScriptLf = $remoteScript -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($localHelper, $remoteScriptLf, $utf8NoBom)

    Write-Step "Uzak temp klasörü hazırlanıyor"
    Invoke-External -Command "ssh" `
        -Arguments ($sshArgs + @($sshTarget, "mkdir -p '$escapedRemoteTempDir'")) `
        -FailureMessage "Uzak sunucuda temp klasörü oluşturulamadı."

    Write-Step "Zip paketi upload ediliyor"
    Invoke-External -Command "scp" `
        -Arguments ($scpArgs + @($localZip, "${sshTarget}:$remoteZipPath")) `
        -FailureMessage "Zip upload başarısız oldu."

    Write-Step "Remote deploy script upload ediliyor"
    Invoke-External -Command "scp" `
        -Arguments ($scpArgs + @($localHelper, "${sshTarget}:$remoteHelperPath")) `
        -FailureMessage "Remote helper script upload başarısız oldu."

    Write-Step "Deploy başlatılıyor"
    Invoke-External -Command "ssh" `
        -Arguments ($sshArgs + @(
            $sshTarget,
            "sed -i 's/\r$//' '$escapedRemoteHelperPath' && chmod +x '$escapedRemoteHelperPath' && '$escapedRemoteHelperPath'"
        )) `
        -FailureMessage "Deploy işlemi başarısız oldu."

    Write-Host ""
    Write-Host "Deploy tamamlandı." -ForegroundColor Green
    Write-Host "Local log:  $localLog" -ForegroundColor Yellow
    Write-Host "Remote log: $remoteLogPath" -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Host "Deploy başarısız oldu: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Local log:  $localLog" -ForegroundColor Yellow
    Write-Host "Remote log: $remoteLogPath" -ForegroundColor Yellow
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }

    Remove-Item $localZip -Force -ErrorAction SilentlyContinue
    Remove-Item $localHelper -Force -ErrorAction SilentlyContinue
}