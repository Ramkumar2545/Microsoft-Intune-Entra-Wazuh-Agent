# Microsoft Intune + Entra ID Integrated Wazuh Agent Deployment (Please Test In Non-Production One-time and Push To Production )

![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Deployment](https://img.shields.io/badge/deployment-Microsoft%20Intune-0078D4)
![Identity](https://img.shields.io/badge/identity-Entra%20ID-00A4EF)
![Agent](https://img.shields.io/badge/Wazuh-4.x-blueviolet)
![License](https://img.shields.io/badge/license-MIT-green)

Automated Wazuh agent deployment to Windows endpoints via Microsoft Intune Win32 apps, using Entra ID device groups for targeting. Install, detection, and uninstall logic live in PowerShell scripts (not raw MSI command lines), so failures are logged, idempotent, and debuggable. The repository ships with a built-in path for handling future Wazuh version upgrades — bump a version number, repackage, and update the existing Intune app — without ever creating a duplicate app object.

---

## Overview / Architecture

```
Entra ID device group  -->  Intune Win32 app (PowerShell-script-based)  -->  Deploy / Detect / Uninstall scripts  -->  Wazuh manager enrollment
```

1. **Entra ID device group** — a security group with Assigned membership, containing the target Windows device objects (not user objects).
2. **Intune Win32 app** — a `.intunewin` package built from this repo's `Scripts/` folder, assigned as Required to the Entra ID group.
3. **Deploy / Detect / Uninstall scripts** — PowerShell scripts run by the Intune Management Extension in SYSTEM context. Deploy installs and configures the agent, Detect tells Intune whether a reinstall is needed, Uninstall removes the agent cleanly.
4. **Wazuh manager enrollment** — the agent registers itself against the manager IP/FQDN and joins the specified agent group, which must already exist on the manager.

Two supported phases live side by side in this repo:

| Phase | Folder | Purpose |
|---|---|---|
| **Phase 1** | `Scripts/Phase-1-Current/` | Deploy the current pinned Wazuh version to new/unenrolled devices. |
| **Phase 2** | `Scripts/Phase-2-Upgrade/` | Upgrade an already-deployed fleet to a new Wazuh version by updating the **existing** Intune app in place — no duplicate app object, no re-targeting of assignments. |

---

## Prerequisites

- Intune Administrator or Application Administrator role
- Entra ID Global Administrator or Groups Administrator role (to create device security groups)
- A reachable Wazuh manager with `authd` enabled (port 1515 for enrollment, 1514 for events)
- A Windows admin workstation with PowerShell 5.1+ and internet access
- The target Wazuh agent group already created **on the manager** before any device attempts enrollment:

```bash
sudo /var/ossec/bin/agent_groups -a -g M365-Team-1
```

---

## Phase 1 — Deploy the current version

### 1.1 Set the version and manager values (CLI)

Three values drive every deployment, all defined in the `param()` block at the top of `Scripts/Phase-1-Current/Deploy-WazuhAgent.ps1`:

```powershell
param(
    [Parameter(Mandatory = $true)]
    [string]$WazuhManager,

    [Parameter(Mandatory = $false)]
    [string]$WazuhVersion = "4.14.7-1",

    [Parameter(Mandatory = $false)]
    [string]$WazuhGroup = "windows-endpoints",
    ...
)
```

**Option A — command-line parameters (recommended, no file editing):**

```powershell
.\Deploy-WazuhAgent.ps1 -WazuhManager "192.168.1.195" -WazuhGroup "M365-Team-1"
```

**Option B — hardcoded defaults inside the `param()` block (for convenience when the same values are always used):**

Edit these two lines in `Scripts/Phase-1-Current/Deploy-WazuhAgent.ps1`:

```powershell
    [string]$WazuhVersion = "4.14.7-1",
    ...
    [string]$WazuhGroup = "windows-endpoints",
```

to:

```powershell
    [string]$WazuhVersion = "4.14.7-1",
    ...
    [string]$WazuhGroup = "M365-Team-1",
```

`$WazuhManager` has no default (it is `Mandatory`) — it must always be supplied, either as a parameter or by adding a default value the same way.

### 1.2 Local CLI test before touching Intune

```powershell
New-Item -ItemType Directory -Path "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Scripts" -Force
New-Item -ItemType Directory -Path "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Tools" -Force
New-Item -ItemType Directory -Path "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Output" -Force

Set-ExecutionPolicy Bypass -Scope Process -Force

cd "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Scripts\Phase-1-Current"
.\Deploy-WazuhAgent.ps1 -WazuhManager "192.168.1.195" -WazuhGroup "M365-Team-1"
```

Expected successful log tail (also written to `C:\ProgramData\WazuhDeploy\deploy.log`):

```
[2026-08-21 10:15:32][OK] WazuhSvc detected. Current status: Running
[2026-08-21 10:15:32][OK] Startup type set to Automatic.
[2026-08-21 10:15:32][OK] WazuhSvc service was already running.
[2026-08-21 10:15:42][OK] FINAL VERIFICATION: Wazuh agent installed and operational.
[2026-08-21 10:15:42][OK] Manager   : 192.168.1.195
[2026-08-21 10:15:42][OK] Group     : M365-Team-1
[2026-08-21 10:15:42][OK] Name      : WIN11-TEST-01
[2026-08-21 10:15:42][OK] Installed version: 4.14.7.0
[2026-08-21 10:15:42][OK] Completed successfully: Deployment completed successfully
```

Then confirm detection reports success (exit code `0`):

```powershell
.\Detect-WazuhAgent.ps1
echo "Exit code: $LASTEXITCODE"
```

Finally, reset the machine to a clean state before the real Intune deployment:

```powershell
.\Uninstall-WazuhAgent.ps1
```

### 1.3 Package with the Win32 Content Prep Tool (CLI)

Download the **pinned v1.8.7 release** (not `master`) from the official [Microsoft-Win32-Content-Prep-Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/tag/v1.8.7.0) releases page:

```powershell
Invoke-WebRequest -Uri "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/download/v1.8.7.0/IntuneWinAppUtil.exe" -OutFile "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Tools\IntuneWinAppUtil.exe"
```

Run it in silent mode (`-q`), pointing at the `Scripts` folder as the source directory and `Deploy-WazuhAgent.ps1` as the setup file:

```powershell
cd "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Tools"
.\IntuneWinAppUtil.exe -c "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Scripts\Phase-1-Current" -s "Deploy-WazuhAgent.ps1" -o "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Output" -q
```

This produces `Output\Deploy-WazuhAgent.intunewin`.

### 1.4 Create Entra ID device group (CLI, Microsoft Graph PowerShell)

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser -Force
Connect-MgGraph -Scopes "Group.ReadWrite.All", "Device.Read.All"

$group = New-MgGroup -DisplayName "Wazuh-Pilot-Devices" `
    -MailEnabled:$false `
    -MailNickname "WazuhPilotDevices" `
    -SecurityEnabled:$true `
    -GroupTypes @() `
    -AdditionalProperties @{ "membershipType" = "Assigned" }

$device = Get-MgDevice -Filter "displayName eq 'WIN11-TEST-01'"

New-MgGroupMemberByRef -GroupId $group.Id -BodyParameter @{
    "@odata.id" = "https://graph.microsoft.com/v1.0/devices/$($device.Id)"
}
```

> **Note:** `Get-MgDevice` returns the **device object**, not the corresponding user object. Adding a user object to this group will not target the machine for a device-based Win32 app assignment.

### 1.5 Upload and configure the Win32 app in Intune (GUI)

1. Go to **Apps → Windows → Windows apps → Create → Windows app (Win32)**.
2. Upload `Output\Deploy-WazuhAgent.intunewin`.

**App information:**

| Field | Value |
|---|---|
| Name | Wazuh Agent |
| Publisher | Wazuh Inc |
| App Version | 4.14.7-1 |
| Show as featured app in Company Portal | No |

**Program:**

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File "Deploy-WazuhAgent.ps1" -WazuhManager "192.168.1.195" -WazuhGroup "M365-Team-1"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -NonInteractive -File "Uninstall-WazuhAgent.ps1"` |
| Install behavior | System |
| Installation time required (minutes) | 60 |

**Requirements:**

| Field | Value |
|---|---|
| Check OS architecture matches system requirements | No |
| Minimum operating system | Windows 10 21H2 |

**Detection rules:**

| Field | Value |
|---|---|
| Rules format | Use a custom detection script |
| Script file | `Detect-WazuhAgent.ps1` |
| Run script as 32-bit process on 64-bit clients | No |

**Assignments:**

| Assignment type | Group |
|---|---|
| Required | Wazuh-Pilot-Devices |

> **Critical gotcha:** an empty Assignments table still shows **"Assigned: Yes"** in the app overview, but the **Device status** tab stays at **0 TOTAL** forever. "Assigned: Yes" only means the app was *saved* with an assignment section touched — it does **not** confirm a group or "All devices"/"All users" was actually added. Always re-open **Assignments** after saving and verify the group name is listed under the correct intent (Required/Available/Uninstall).

### 1.6 Verify the deployment (CLI + GUI)

Force an Intune sync on the target device:

```powershell
Start-Process "ms-settings:workplace"
```

(or manually: **Settings → Accounts → Access work or school → select the connected account → Info → Sync**)

Then tail the relevant logs:

```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log" -Tail 50 -Wait
```

```powershell
Get-Content "C:\ProgramData\WazuhDeploy\deploy.log" -Tail 50 -Wait
```

Finally, confirm the agent shows up under the `M365-Team-1` group on the Wazuh dashboard's **Agents → Groups** page.

---

## Phase 2 — Upgrading to a new Wazuh version (e.g. 4.14.8, 5.1.1)

### 2.1 Upgrade the Wazuh manager first, always

Check the current manager version before touching any agent:

```bash
sudo /var/ossec/bin/wazuh-control info
```

**Compatibility rule:** the manager version must always be **greater than or equal to** the agent version. Never deploy an agent version newer than the manager.

### 2.2 Update the version number in the deploy script (CLI)

Edit the `$WazuhVersion` default in `Scripts/Phase-2-Upgrade/Deploy-WazuhAgent.ps1`.

**Routine patch bump (4.14.7-1 → 4.14.8-1):**

```diff
-    [string]$WazuhVersion = "4.14.7-1",
+    [string]$WazuhVersion = "4.14.8-1",
```

**Major version bump (→ 5.1.1-1):**

```diff
-    [string]$WazuhVersion = "4.14.7-1",
+    [string]$WazuhVersion = "5.1.1-1",
```

> A major version jump (e.g. 4.x → 5.x) may also change the download URL path from `packages.wazuh.com/4.x/windows/...` to `packages.wazuh.com/5.x/windows/...`. **Verify the real download URL on [packages.wazuh.com](https://packages.wazuh.com/) before assuming the `/4.x/` → `/5.x/` pattern holds** — do not blindly bump the version string and assume the URL still resolves.

### 2.3 Update the version threshold in the detection script (CLI)

Edit `$MinimumExpectedVersion` in `Scripts/Phase-2-Upgrade/Detect-WazuhAgent.ps1`:

```diff
-$MinimumExpectedVersion = "4.14.7"
+$MinimumExpectedVersion = "4.14.8"
```

This matters because **without updating this value, Intune will treat any already-installed version as permanently compliant** and will never re-trigger an install for devices still running an older Wazuh agent — the detection script would keep returning exit `0` regardless of how stale the installed version is.

### 2.4 Repackage (CLI)

Same tool, same flags as section 1.3, pointed at the `Phase-2-Upgrade` folder:

```powershell
cd "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Tools"
.\IntuneWinAppUtil.exe -c "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Scripts\Phase-2-Upgrade" -s "Deploy-WazuhAgent.ps1" -o "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Output" -q
```

This produces a new `.intunewin` with the bumped version baked in.

### 2.5 Update the existing Intune app — do not create a duplicate (GUI)

1. **Apps → Windows → Windows apps →** select the existing **Wazuh Agent** app.
2. **Properties → Edit** (App information) → bump the **App Version** field (e.g. `4.14.8-1`) → **Review + save**.
3. Back on the app page, replace the uploaded package: **Properties → Edit** the app package with the new `.intunewin` from step 2.4 (in tenants without in-place package replacement, see the Supersedence fallback below).
4. **Detection rules → Edit** → upload the updated `Detect-WazuhAgent.ps1` from `Phase-2-Upgrade` → **Review + save**.
5. **Assignments** — leave untouched. The same Entra ID group (`Wazuh-Pilot-Devices`) stays targeted; no re-assignment is needed.
6. **Review + save**.

**Supersedence fallback** — if the tenant's UI does not allow in-place package replacement on an existing Win32 app:

1. Create a **new** Win32 app object using the Phase-2-Upgrade package and Detect script (repeat section 1.5 with the new files).
2. On the **new** app, go to **App properties → Supersedence** and add the **old** Wazuh Agent app as a superseded app, with **"Uninstall previous version"** enabled.
3. Assign the new app to the same group; Intune will uninstall the old app and install the new one automatically on next check-in.

### 2.6 Verify the upgrade rolled out (CLI + GUI)

On a device still running the old version, force a sync:

```powershell
Start-Process "ms-settings:workplace"
```

Tail the Intune Management Extension log:

```powershell
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log" -Tail 50 -Wait
```

Expect to see the detection script exit `1` on the old version (out of date per `$MinimumExpectedVersion`), which triggers `Deploy-WazuhAgent.ps1` to run its uninstall-then-reinstall path automatically.

Confirm the new version landed by checking the final verification block in `deploy.log`:

```powershell
Get-Content "C:\ProgramData\WazuhDeploy\deploy.log" -Tail 20
```

```
[2026-08-21 11:02:10][OK] FINAL VERIFICATION: Wazuh agent installed and operational.
[2026-08-21 11:02:10][OK] Installed version: 4.14.8.0
```

---

## Uninstalling / decommissioning an agent entirely

### 1. Local/manual uninstall (CLI)

Run directly on the target machine:

```powershell
cd "C:\Deploy\Microsoft-Intune-Entra-Wazuh-Agent\Scripts\Phase-1-Current"
.\Uninstall-WazuhAgent.ps1
```

### 2. Fleet-wide decommission via Intune (GUI)

1. Go to the **Wazuh Agent** app → **Assignments**.
2. Remove the device (or its group) from the **Required** assignment.
3. Add the same device/group under the **Uninstall** assignment intent instead.
4. Save. Intune will automatically run the app's **Uninstall command** on the device's next check-in.

Verify locally on the device once the uninstall has run:

```powershell
Get-Service WazuhSvc -ErrorAction SilentlyContinue
```

This should return **nothing** (no output) once decommissioning is complete.

---

## Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| `File cannot be loaded. Is not digitally signed.` | Local execution policy blocks unsigned scripts. | `Set-ExecutionPolicy Bypass -Scope Process -Force` before running the script interactively. |
| `-ErrorAction is not recognized` / `-ArgumentList is not recognized` | A broken backtick (`` ` ``) line-continuation followed by a blank line — PowerShell only honors a continuation when there is **no** blank line between the backtick and the next line. | Rewrite the statement on a single line (all parameters on one line), or use a continuation with zero blank lines in between. |
| Detection reports "not found" immediately after a successful install | Detection script checks only for the legacy `ossec-agent.exe` name instead of the current Wazuh 4.x binary name `wazuh-agent.exe`. | Check `wazuh-agent.exe` first, fall back to `ossec-agent.exe` only for legacy compatibility (already implemented in `Detect-WazuhAgent.ps1`). |
| Device status shows **0 TOTAL** despite "Assigned: Yes" | Assignments table is actually empty — no group or "All devices" was ever added, but the app was saved anyway. | Re-open **Assignments**, add the Entra ID device group under the correct intent, and save again. |
| Install downloads successfully in IME logs but never executes | The Intune Management Extension process kept restarting (session logoff, VM snapshot revert, reboot) before it could reach the install step. | Let the device sit idle and logged in, uninterrupted, for 15-20 minutes to let IME complete the full install cycle. |
| Agent installs but never enrolls in the target Wazuh group | Group name mismatch (agent group names are case-sensitive) or the group did not exist on the manager before install. | Confirm the exact group name with `agent_groups -l` on the manager, and create it first with `agent_groups -a -g <name>` if missing. |

---

## Repository structure

```
Microsoft-Intune-Entra-Wazuh-Agent/
├── README.md                          # This document
├── Scripts/
│   ├── Phase-1-Current/               # Deploy the current pinned Wazuh version
│   │   ├── Deploy-WazuhAgent.ps1      # Install / idempotent re-check / start service
│   │   ├── Detect-WazuhAgent.ps1      # Read-only detection for Intune's Detection rules field
│   │   └── Uninstall-WazuhAgent.ps1   # Silent removal for Intune's Uninstall command field
│   └── Phase-2-Upgrade/               # Template to copy forward for every future version bump
│       ├── Deploy-WazuhAgent.ps1      # Same as Phase 1, with explicit version-aware upgrade logic
│       └── Detect-WazuhAgent.ps1      # Same as Phase 1, plus a $MinimumExpectedVersion gate
├── Tools/                             # IntuneWinAppUtil.exe (Win32 Content Prep Tool) goes here
└── Output/                            # Generated .intunewin packages land here
```

| Folder | Purpose |
|---|---|
| `Scripts/Phase-1-Current` | Use for first-time deployment of the currently pinned Wazuh version to new devices. |
| `Scripts/Phase-2-Upgrade` | Use when bumping to a new Wazuh version on an already-deployed fleet; update the existing Intune app in place. |
| `Tools` | Holds the Win32 Content Prep Tool executable (not checked in — download per section 1.3). |
| `Output` | Holds generated `.intunewin` packages (not checked in — build artifacts). |

---

## License

MIT
