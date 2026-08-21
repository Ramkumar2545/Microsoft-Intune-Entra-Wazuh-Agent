#Requires -RunAsAdministrator

<#
.SYNOPSIS
    DETECTION script for Microsoft Intune, with a version gate for upgrade rollouts.
    Determines whether the Wazuh agent is installed, Running, AND at least at the
    minimum expected version.

.DESCRIPTION
    Intune runs this script to decide whether it needs to re-run the deployment.
    Exit 0 = correctly installed and up to date (Intune will NOT re-run the deploy).
    Exit 1 = not installed, defective, or out of date (Intune will run the deploy).

    Success criteria:
    - wazuh-agent.exe executable is present (fallback: legacy ossec-agent.exe,
      kept for compatibility with pre-4.x agents that used the old binary name)
    - WazuhSvc service exists and is in Running state
    - Installed DisplayVersion >= $MinimumExpectedVersion

    Without the version gate below, Intune would treat any installed version as
    permanently compliant and never re-trigger an install for devices still
    running an older Wazuh agent version.

.NOTES
    This script goes in the "Detection rules" custom script field of the Win32 app in Intune.
    It does NOT modify anything on the system. It only reads state.
#>

# <-- Update this value for every new Wazuh release.
$MinimumExpectedVersion = "4.14.7"

$exitCode = 1

try {
    $installDir = "C:\Program Files (x86)\ossec-agent"

    # Wazuh changed the agent executable name from ossec-agent.exe to
    # wazuh-agent.exe starting with the 4.x line, even though the install
    # directory is still named "ossec-agent" for backward compatibility.
    # Checking only for the legacy ossec-agent.exe name caused this script
    # to report "not found" immediately after a fully successful install,
    # which made Intune mark the deployment as Failed even though the
    # agent was installed and the service was Running. Always check the
    # current name first, and keep the legacy name only as a fallback.

    # Primary check: current executable name (Wazuh 4.x)
    $currentExePath = Join-Path $installDir "wazuh-agent.exe"

    # Fallback check: legacy executable name (older Wazuh releases)
    $legacyExePath = Join-Path $installDir "ossec-agent.exe"

    $exeFound = $false
    if (Test-Path $currentExePath) {
        Write-Output "DETECTION: wazuh-agent.exe found at $currentExePath."
        $exeFound = $true
    } elseif (Test-Path $legacyExePath) {
        Write-Output "DETECTION: legacy ossec-agent.exe found at $legacyExePath."
        $exeFound = $true
    }

    if (-not $exeFound) {
        Write-Output "DETECTION: neither wazuh-agent.exe nor ossec-agent.exe found in $installDir."
        exit 1
    }

    # Check that the service exists and is Running
    $svc = Get-Service "WazuhSvc" -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Output "DETECTION: WazuhSvc service not found."
        exit 1
    }

    if ($svc.Status -ne "Running") {
        Write-Output "DETECTION: WazuhSvc exists but status is $($svc.Status)."
        exit 1
    }

    # Version gate: read the installed DisplayVersion and compare against the
    # minimum expected version so that Intune re-triggers the deploy on
    # out-of-date devices instead of treating any installed version as
    # permanently compliant.
    $installed = Get-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Wazuh*" } | Select-Object -First 1

    if ($null -eq $installed) {
        Write-Output "DETECTION: WazuhSvc is Running but no uninstall registry entry was found to read the version from."
        exit 1
    }

    $installedVersionClean = ($installed.DisplayVersion -split "-")[0]
    $minimumVersionClean = ($MinimumExpectedVersion -split "-")[0]

    try {
        $installedVersionObj = [version]$installedVersionClean
        $minimumVersionObj = [version]$minimumVersionClean
    } catch {
        Write-Output "DETECTION: Could not parse version numbers for comparison: $_"
        exit 1
    }

    if ($installedVersionObj -lt $minimumVersionObj) {
        Write-Output "DETECTION: Installed version ($installedVersionClean) is older than the minimum expected version ($minimumVersionClean)."
        exit 1
    }

    Write-Output "DETECTION: Wazuh agent installed, Running, and at or above minimum expected version ($installedVersionClean >= $minimumVersionClean). OK."
    exit 0
} catch {
    Write-Output "DETECTION: Error during verification: $_"
    exit 1
}
