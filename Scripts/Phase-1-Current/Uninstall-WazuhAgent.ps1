#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Silent uninstall of the Wazuh agent.
    Compatible with Intune (Win32 app "Uninstall command" field).

.NOTES
    Can be run directly or used as an Intune uninstall script.
    Always exits 0 so that a partial failure does not block Intune's uninstall workflow.
#>

$ErrorActionPreference = "SilentlyContinue"

Write-Output "Starting Wazuh agent uninstall..."

# Stop the service first
$svc = Get-Service "WazuhSvc" -ErrorAction SilentlyContinue
if ($null -ne $svc -and $svc.Status -eq "Running") {
    Stop-Service "WazuhSvc" -Force
    Start-Sleep -Seconds 5
    Write-Output "WazuhSvc service stopped."
}

# Look up the installation GUID in the registry (64-bit and 32-bit views)
$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)

$found = $false

foreach ($regPath in $uninstallPaths) {
    $entries = Get-ChildItem $regPath -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
        $props = Get-ItemProperty $entry.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -like "*Wazuh*") {
            Write-Output "Found: $($props.DisplayName) - $($props.DisplayVersion)"

            if ($entry.PSChildName -match "^\{[0-9A-Fa-f\-]+\}$") {
                $guid = $entry.PSChildName
                Write-Output "GUID: $guid"

                $proc = Start-Process "msiexec.exe" -ArgumentList "/x $guid /q" -Wait -PassThru -NoNewWindow
                Write-Output "msiexec returned: $($proc.ExitCode)"

                $found = $true
                break
            }
        }
    }
    if ($found) { break }
}

if (-not $found) {
    Write-Output "No Wazuh installation found in the registry. It may already be uninstalled."
}

# Clean up leftover directory if it exists
$agentDir = "C:\Program Files (x86)\ossec-agent"
if (Test-Path $agentDir) {
    Remove-Item $agentDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "Leftover directory removed: $agentDir"
}

Write-Output "Uninstall completed."
exit 0
