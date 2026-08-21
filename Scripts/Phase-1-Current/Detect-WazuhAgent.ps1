#Requires -RunAsAdministrator

<#
.SYNOPSIS
    DETECTION script for Microsoft Intune.
    Determines whether the Wazuh agent is installed and operational.

.DESCRIPTION
    Intune runs this script to decide whether it needs to re-run the deployment.
    Exit 0 = correctly installed (Intune will NOT re-run the deploy).
    Exit 1 = not installed or defective (Intune will run the deploy).

    Success criteria:
    - wazuh-agent.exe executable is present (fallback: legacy ossec-agent.exe,
      kept for compatibility with pre-4.x agents that used the old binary name)
    - WazuhSvc service exists and is in Running state

.NOTES
    This script goes in the "Detection rules" custom script field of the Win32 app in Intune.
    It does NOT modify anything on the system. It only reads state.
#>

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

    Write-Output "DETECTION: Wazuh agent installed and Running. OK."
    exit 0
} catch {
    Write-Output "DETECTION: Error during verification: $_"
    exit 1
}
