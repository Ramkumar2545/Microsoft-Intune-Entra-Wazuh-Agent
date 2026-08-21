#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Automated Wazuh agent deployment / upgrade - Compatible with Microsoft Intune.

.DESCRIPTION
    Unified script that downloads, installs, registers, and verifies the Wazuh agent.
    Designed for silent execution via Intune (SYSTEM context, 64-bit PowerShell).
    Also runnable interactively by a local Administrator.

    THIS IS THE UPGRADE TEMPLATE. When a new Wazuh version is released, copy this
    folder forward (or edit in place), bump the $WazuhVersion default below, and
    update the Detect-WazuhAgent.ps1 $MinimumExpectedVersion to match. Nothing
    else in this script needs to change structurally - the version-aware logic
    below already handles: same-or-newer version installed (skip), older version
    installed (uninstall then reinstall), or not installed (fresh install).

.PARAMETER WazuhManager
    IP or FQDN of the Wazuh Manager server. REQUIRED.

.PARAMETER WazuhVersion
    Agent version to install. Default: 4.14.7-1
    <-- Update this value for every new Wazuh release.

.PARAMETER WazuhGroup
    Agent group on the Wazuh Manager. Default: "windows-endpoints"

.PARAMETER WazuhAgentName
    Agent name. Default: the computer's hostname.

.PARAMETER RegistrationPassword
    Registration password if the manager requires one. Optional.

.PARAMETER LogPath
    Log file path. Default: C:\ProgramData\WazuhDeploy\deploy.log

.EXAMPLE
    .\Deploy-WazuhAgent.ps1 -WazuhManager "192.168.1.195" -WazuhGroup "M365-Team-1"

.NOTES
    Platform: Windows 10/11, Windows Server 2016/2019/2022/2025
    Context: SYSTEM (Intune) or local Administrator
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WazuhManager,

    [Parameter(Mandatory = $false)]
    [string]$WazuhVersion = "4.14.7-1",

    [Parameter(Mandatory = $false)]
    [string]$WazuhGroup = "windows-endpoints",

    [Parameter(Mandatory = $false)]
    [string]$WazuhAgentName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$RegistrationPassword = "",

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\WazuhDeploy\deploy.log"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# LOGGING FUNCTIONS
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "OK")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp][$Level] $Message"

    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $LogPath -Value $logLine -Encoding UTF8

    switch ($Level) {
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "OK"    { Write-Host $logLine -ForegroundColor Green }
        default { Write-Host $logLine }
    }
}

function Exit-WithCode {
    param([int]$Code, [string]$Reason)
    if ($Code -eq 0) {
        Write-Log "Completed successfully: $Reason" -Level "OK"
    } else {
        Write-Log "Completed with error ($Code): $Reason" -Level "ERROR"
    }
    Write-Log "=================================================="
    exit $Code
}

# ---------------------------------------------------------------------------
# START
# ---------------------------------------------------------------------------
Write-Log "=================================================="
Write-Log "Wazuh Agent Deployment / Upgrade"
Write-Log "Host      : $env:COMPUTERNAME"
Write-Log "Manager   : $WazuhManager"
Write-Log "Version   : $WazuhVersion"
Write-Log "Group     : $WazuhGroup"
Write-Log "Name      : $WazuhAgentName"
Write-Log "User      : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "OS        : $((Get-CimInstance Win32_OperatingSystem).Caption)"
Write-Log "=================================================="

# ---------------------------------------------------------------------------
# DETECT EXISTING INSTALLATION (version-aware upgrade path)
# ---------------------------------------------------------------------------
$wazuhInstalled = $false
$installedVersion = ""

try {
    $installed = Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Wazuh*" }

    if ($null -ne $installed) {
        $wazuhInstalled = $true
        $installedVersion = $installed.DisplayVersion
        Write-Log "Wazuh agent already installed. Detected version: $installedVersion" -Level "WARN"
    }
} catch {
    Write-Log "Could not query the installed-programs registry: $_" -Level "WARN"
}

if ($wazuhInstalled) {
    # Strip the "-N" revision suffix (e.g. "4.14.7-1" -> "4.14.7") before casting to [version]
    $installedVersionClean = ($installedVersion -split "-")[0]
    $targetVersionClean = ($WazuhVersion -split "-")[0]

    $installedVersionObj = $null
    $targetVersionObj = $null
    try {
        $installedVersionObj = [version]$installedVersionClean
        $targetVersionObj = [version]$targetVersionClean
    } catch {
        Write-Log "Could not parse version numbers for comparison: $_" -Level "WARN"
    }

    $svc = Get-Service "WazuhSvc" -ErrorAction SilentlyContinue

    if ($null -ne $installedVersionObj -and $null -ne $targetVersionObj -and $installedVersionObj -ge $targetVersionObj) {
        if ($null -ne $svc -and $svc.Status -eq "Running") {
            Write-Log "Installed version ($installedVersionClean) is already >= target version ($targetVersionClean) and the service is running. No changes needed." -Level "OK"
            Exit-WithCode 0 "Existing installation detected and operational"
        } else {
            Write-Log "Installed version is current but WazuhSvc is not running. Attempting to start it..." -Level "WARN"
            try {
                Start-Service "WazuhSvc" -ErrorAction Stop
                Write-Log "WazuhSvc service started successfully." -Level "OK"
                Exit-WithCode 0 "Service started on top of existing installation"
            } catch {
                Write-Log "Could not start the service: $_. Continuing with reinstallation..." -Level "WARN"
            }
        }
    } elseif ($null -ne $installedVersionObj -and $null -ne $targetVersionObj -and $installedVersionObj -lt $targetVersionObj) {
        Write-Log "Installed version ($installedVersionClean) is older than target version ($targetVersionClean). Uninstalling before upgrade..." -Level "WARN"
        $uninstallScript = Join-Path $PSScriptRoot "Uninstall-WazuhAgent.ps1"
        if (-not (Test-Path $uninstallScript)) {
            # Fall back to the Phase-1-Current uninstall script if this folder doesn't have its own copy
            $uninstallScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Phase-1-Current\Uninstall-WazuhAgent.ps1"
        }
        if (Test-Path $uninstallScript) {
            & $uninstallScript
            Write-Log "Uninstall script finished ($uninstallScript). Proceeding with fresh install of $WazuhVersion." -Level "INFO"
        } else {
            Write-Log "Uninstall script not found. Proceeding with install anyway (msiexec will attempt an in-place upgrade)." -Level "WARN"
        }
    } else {
        Write-Log "Could not determine a clear version comparison. Proceeding with install anyway." -Level "WARN"
    }
}

# ---------------------------------------------------------------------------
# DOWNLOAD THE INSTALLER
# ---------------------------------------------------------------------------
$msiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVersion.msi"
$msiPath = "$env:TEMP\wazuh-agent-$WazuhVersion.msi"
$maxRetries = 3
$retryDelay = 10

Write-Log "Downloading installer from: $msiUrl"

$downloaded = $false
for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
    try {
        Write-Log "Download attempt $attempt/$maxRetries..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($msiUrl, $msiPath)

        if ((Test-Path $msiPath) -and (Get-Item $msiPath).Length -gt 1MB) {
            Write-Log "Download complete. Size: $([Math]::Round((Get-Item $msiPath).Length / 1MB, 1)) MB" -Level "OK"
            $downloaded = $true
            break
        } else {
            Write-Log "File downloaded but size looks suspicious. Retrying..." -Level "WARN"
        }
    } catch {
        Write-Log "Download error (attempt $attempt): $_" -Level "WARN"
        if ($attempt -lt $maxRetries) {
            Start-Sleep -Seconds $retryDelay
        }
    }
}

if (-not $downloaded) {
    Exit-WithCode 1 "Could not download the installer after $maxRetries attempts"
}

# ---------------------------------------------------------------------------
# SILENT INSTALLATION
# ---------------------------------------------------------------------------
Write-Log "Starting silent agent installation..."

$msiArgs = @("/i", "`"$msiPath`"", "/q", "WAZUH_MANAGER=`"$WazuhManager`"", "WAZUH_REGISTRATION_SERVER=`"$WazuhManager`"", "WAZUH_AGENT_GROUP=`"$WazuhGroup`"", "WAZUH_AGENT_NAME=`"$WazuhAgentName`"")

if ($RegistrationPassword -ne "") {
    $msiArgs += "WAZUH_REGISTRATION_PASSWORD=`"$RegistrationPassword`""
    Write-Log "Registration password included in the install arguments."
}

try {
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    $exitCode = $process.ExitCode
    Write-Log "msiexec finished with exit code: $exitCode"

    if ($exitCode -eq 0) {
        Write-Log "Installation completed successfully." -Level "OK"
    } elseif ($exitCode -eq 3010) {
        Write-Log "Installation completed. A system reboot is required." -Level "WARN"
    } else {
        Exit-WithCode $exitCode "msiexec returned error code: $exitCode"
    }
} catch {
    Exit-WithCode 1 "Error running msiexec: $_"
} finally {
    if (Test-Path $msiPath) {
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        Write-Log "Temporary MSI file removed."
    }
}

# ---------------------------------------------------------------------------
# WAIT FOR AND START THE SERVICE
# ---------------------------------------------------------------------------
Write-Log "Waiting for the WazuhSvc service to become available..."

$maxWait = 90
$elapsed = 0
$svcReady = $false

while ($elapsed -lt $maxWait) {
    $svc = Get-Service "WazuhSvc" -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        $svcReady = $true
        Write-Log "WazuhSvc detected. Current status: $($svc.Status)" -Level "OK"
        break
    }
    Start-Sleep -Seconds 5
    $elapsed += 5
    Write-Log "Still waiting for the service... ($elapsed seconds)"
}

if (-not $svcReady) {
    Exit-WithCode 1 "WazuhSvc service did not appear after $maxWait seconds"
}

try {
    Set-Service "WazuhSvc" -StartupType Automatic
    Write-Log "Startup type set to Automatic."

    $svc = Get-Service "WazuhSvc"
    if ($svc.Status -ne "Running") {
        Start-Service "WazuhSvc" -ErrorAction Stop
        Write-Log "WazuhSvc service started." -Level "OK"
    } else {
        Write-Log "WazuhSvc service was already running." -Level "OK"
    }
} catch {
    Exit-WithCode 1 "Could not start the WazuhSvc service: $_"
}

# ---------------------------------------------------------------------------
# FINAL VERIFICATION
# ---------------------------------------------------------------------------
Start-Sleep -Seconds 10
$svc = Get-Service "WazuhSvc" -ErrorAction SilentlyContinue

if ($null -ne $svc -and $svc.Status -eq "Running") {
    Write-Log "FINAL VERIFICATION: Wazuh agent installed and operational." -Level "OK"
    Write-Log "Manager   : $WazuhManager"
    Write-Log "Group     : $WazuhGroup"
    Write-Log "Name      : $WazuhAgentName"

    try {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        $wazuhReg = Get-ChildItem $regPath | Get-ItemProperty | Where-Object { $_.DisplayName -like "*Wazuh*" } | Select-Object -First 1
        if ($wazuhReg) {
            Write-Log "Installed version: $($wazuhReg.DisplayVersion)" -Level "OK"
        }
    } catch {
        # Non-critical
    }

    Exit-WithCode 0 "Deployment completed successfully"
} else {
    $status = if ($null -ne $svc) { $svc.Status } else { "NOT FOUND" }
    Exit-WithCode 1 "WazuhSvc is not Running after installation. Status: $status"
}
