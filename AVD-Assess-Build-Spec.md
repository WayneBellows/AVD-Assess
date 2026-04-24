# AVD-Assess — Build Specification for Claude Code

**Version:** 1.0  
**Author:** Wayne Bellows (wbellows@getnerdio.com)  
**Website:** https://modern-euc.com  
**Target repo:** github.com/waynebellows/AVD-Assess  
**License:** MIT

---

## 1. Project Overview

AVD-Assess is a community open-source PowerShell tool that connects to an Azure subscription and runs a series of best-practice health checks against Azure Virtual Desktop (AVD) environments. It produces a self-contained HTML report with traffic-light scoring and actionable remediation guidance.

**The problem it solves:** There is no free, open-source, automated health checker for AVD environments. Microsoft's Well-Architected Framework for AVD exists as documentation, but there is no tool that operationalises those checks. AVD administrators currently rely on manual reviews, expensive third-party tools, or nothing at all.

**Who it is for:** AVD administrators, Microsoft partners, and IT consultants managing AVD environments — particularly those who want a fast, automated way to identify configuration gaps, cost inefficiencies, and security risks across one or more host pools.

**Core value proposition:**
- Run it in under 5 minutes against any AVD environment
- Get a scored, categorised HTML report you can share with stakeholders
- Every finding has a specific remediation action and a Microsoft Learn link
- No software to install beyond the standard Az PowerShell modules
- Completely free and open-source

---

## 2. Repository Structure

The tool should be delivered as a single-file PowerShell script for maximum simplicity and portability. Users should be able to download one file and run it.

```
AVD-Assess/
├── AVD-Assess.ps1       ← Main script (everything in one file)
├── README.md            ← Installation, prerequisites, usage, example output
├── LICENSE              ← MIT license
├── .gitignore           ← Standard PowerShell gitignore
└── CONTRIBUTING.md      ← Basic contribution guidelines
```

**Do not** create a module structure, separate check files, or any dependencies beyond the Az PowerShell modules. The single-file approach is intentional — it maximises portability and lowers the barrier to adoption.

---

## 3. Technology Stack

| Component | Choice | Reason |
|---|---|---|
| Language | PowerShell 7+ | Native Azure tooling for AVD admins |
| Azure auth | Az PowerShell modules | Standard, well-understood by target audience |
| Output | Self-contained HTML | Shareable, no server required, professional output |
| Fonts | Inter (Google Fonts CDN) | Clean, modern, same font used across Wayne's brand |
| Charts | Inline SVG | No JavaScript charting library dependency |

**Required PowerShell modules:**
- `Az.Accounts` — authentication and context management
- `Az.DesktopVirtualization` — host pools, session hosts, scaling plans
- `Az.Compute` — VM properties (Trusted Launch, extensions)
- `Az.Monitor` — diagnostic settings
- `Az.Resources` — resource tags

**Minimum PowerShell version:** 7.0 (for modern string interpolation and parallel support if added later)

---

## 4. Script Parameters

```powershell
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    # Azure subscription ID to assess. If not provided, uses current Az context.

    [string]$TenantId,
    # Azure tenant ID. If not provided, uses current Az context.

    [string]$OutputPath,
    # Where to save the HTML report. Defaults to current directory with timestamp.
    # Example: "C:\Reports\AVD-Assess-20260424.html"

    [string]$HostPoolName,
    # Optional: scope assessment to a single host pool by name.
    # Must be used with -ResourceGroupName.

    [string]$ResourceGroupName,
    # Optional: scope assessment to a specific resource group.

    [switch]$UseExistingConnection,
    # Skip Connect-AzAccount and use the existing Az PowerShell context.
    # Useful for automation or when already authenticated.

    [switch]$OpenReport
    # Automatically open the HTML report in the default browser when complete.
)
```

**Example usage:**

```powershell
# Run against all host pools in the current Az context
.\AVD-Assess.ps1

# Run against a specific subscription and open the report when done
.\AVD-Assess.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -OpenReport

# Run against a single host pool
.\AVD-Assess.ps1 -HostPoolName "hp-prod-pooled-01" -ResourceGroupName "rg-avd-prod"

# Use existing login context (useful in automation)
.\AVD-Assess.ps1 -UseExistingConnection -OutputPath "C:\Reports\avd-health.html"
```

---

## 5. Script Structure

The script should be organised into clearly labelled sections with comment banners:

1. **Header block** — `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`
2. **Helper functions** — `Add-CheckResult`, `Write-Section`, `Get-RdpProperty`, score colour functions
3. **Console banner** — ASCII art banner with tool name, version, website
4. **Azure connection** — connect and set context
5. **Data collection** — fetch all required Azure resources upfront (not inside check functions)
6. **Checks: Cost Optimisation** (4 checks)
7. **Checks: Reliability & Resilience** (4 checks)
8. **Checks: Security Posture** (4 checks)
9. **Checks: Operational Excellence** (4 checks)
10. **Score calculation** — per-category and overall
11. **HTML report generation** — build the full HTML as a here-string
12. **Save and optionally open report**

---

## 6. Check Result Data Model

Every check must call `Add-CheckResult` to register its outcome. The function appends to a script-scoped list `$script:Checks`.

```powershell
function Add-CheckResult {
    param(
        [string]$Category,       # 'Cost' | 'Reliability' | 'Security' | 'Operations'
        [string]$CheckName,      # Short display name, e.g. "Scaling Plan Coverage"
        [ValidateSet('Pass','Warning','Fail','Info')]
        [string]$Status,         # Traffic light status
        [int]$Score,             # 0–100 numeric score for this check
        [string]$Finding,        # What was found (specific, with counts and names)
        [string]$Remediation,    # What to do about it (actionable, specific)
        [string]$LearnMore       # Microsoft Learn URL (optional)
    )
    ...
}
```

**Status definitions:**
- `Pass` (green) — meets best practice, score 100
- `Warning` (amber) — partially meets best practice or a non-critical gap, score 40–80
- `Fail` (red) — does not meet best practice, significant risk or cost impact, score 0–40
- `Info` (teal) — check not applicable to this environment (e.g. no personal host pools), score 100 (excluded from average)

**Category scores** are calculated as the average score of all non-Info checks in that category. The **overall score** is the average of the four category scores.

---

## 7. Data Collection

Fetch all required data **upfront** before running any checks. Store in script-scoped variables. This avoids repeated API calls and makes checks read from in-memory data.

```powershell
# Fetch all host pools in scope
$allHostPools = Get-AzWvdHostPool (with appropriate scope params)

# Fetch all session hosts across all host pools
$allSessionHosts = [list] built by iterating $allHostPools

# Fetch all scaling plans in scope
$allScalingPlans = [list] built by iterating resource groups

# Fetch AVD-related VMs (matched by session host resource IDs)
$allVMs = Get-AzVM -Status | filtered to AVD session hosts

# Fetch diagnostic settings for each host pool
$diagnosticSettings = [hashtable] keyed by host pool resource ID

# Derived convenience collections
$pooledHostPools = $allHostPools | Where-Object { $_.HostPoolType -eq 'Pooled' }
$personalHostPools = $allHostPools | Where-Object { $_.HostPoolType -eq 'Personal' }
```

**Important:** Wrap all data collection in try/catch with graceful fallback. If a specific data fetch fails (e.g. no permissions to read VMs), log a warning to the console and skip the affected checks with an `Info` status rather than terminating the script.

---

## 8. The 16 Checks — Full Specification

### CATEGORY: Cost Optimisation

---

#### CHECK 1: Scaling Plan Coverage

**What it checks:** Whether all pooled host pools have an auto-scaling plan assigned.

**How to detect:**
- Get all scaling plans in the subscription/resource group
- Extract the `HostPoolReference` array from each scaling plan — each entry has a `HostPoolArmPath` property containing the host pool resource ID
- Compare against the list of pooled host pools by resource ID

**Pass:** All pooled host pools have a scaling plan assigned.  
`Score: 100` | `Finding: "All N pooled host pool(s) have a scaling plan configured."`

**Fail:** One or more pooled host pools have no scaling plan.  
`Score: percentage of covered pools (e.g. 2/5 covered = 40)` | Name the uncovered pools in the finding.

**Info:** No pooled host pools exist.

**Remediation (Fail):** "Create and assign a scaling plan to each pooled host pool. Scaling plans can reduce Azure compute costs by 40–70% for environments with predictable daily usage patterns by automatically deallocating idle session hosts outside peak hours."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan

---

#### CHECK 2: Start VM on Connect (Personal Host Pools)

**What it checks:** Whether personal host pools have Start VM on Connect enabled, which avoids VMs running 24/7 for users who only connect during business hours.

**How to detect:**
- Filter `$personalHostPools`
- Check `$hp.StartVMOnConnect -eq $true` for each

**Pass:** All personal host pools have StartVMOnConnect = true.  
**Warning:** One or more personal host pools have StartVMOnConnect = false.  
**Info:** No personal host pools exist.

`Score (Warning): 40`

**Remediation (Warning):** "Enable Start VM on Connect on all personal host pools. This ensures personal VMs are only running when users need them, rather than 24/7. Combine with an auto-shutdown schedule for maximum savings. A personal VM running 24/7 costs approximately 3× more than one using Start VM on Connect with an 8-hour working day pattern."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect

---

#### CHECK 3: Unhealthy Hosts Still in Session Rotation

**What it checks:** Whether session hosts that are in an unhealthy state are still marked as accepting new sessions, meaning they are consuming compute without serving users effectively.

**How to detect:**
- Find session hosts where `$host.Status` is in `@('Unavailable', 'NeedsAssistance', 'UpgradeFailed', 'NoHeartbeat')` AND `$host.AllowNewSession -eq $true`

**Pass:** No unhealthy hosts are accepting new sessions.  
**Warning:** One or more unhealthy hosts are still in rotation.

`Score (Warning): 30` | List the affected host names in the finding.

**Remediation (Warning):** "Set AllowNewSession = false on unhealthy hosts to drain them from the load balancer. This prevents new users from connecting to broken session hosts. Investigate the underlying health issue (check AVD agent logs at C:\Program Files\Microsoft RDAgent\) and either remediate the VM or replace the session host."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/drain-mode

---

#### CHECK 4: Max Session Limit Configuration

**What it checks:** Whether pooled host pools have a sensible max session limit set, rather than the default value (999999) which prevents effective load balancing.

**How to detect:**
- For each pooled host pool, check `$hp.MaxSessionLimit`
- Flag as bad if `$hp.MaxSessionLimit -ge 999999` or `$hp.MaxSessionLimit -le 0`

**Pass:** All pooled host pools have a realistic max session limit.  
**Warning:** One or more pooled host pools are at the default (999999).  
**Info:** No pooled host pools exist.

`Score (Warning): 50` | List affected pool names.

**Remediation (Warning):** "Set a realistic max session limit based on your VM size and workload type. Recommended starting points: D4s_v5 (4 vCPU / 16 GB) → 8–12 sessions for knowledge workers, 12–16 for task workers. D8s_v5 (8 vCPU / 32 GB) → 16–24 sessions for knowledge workers. Setting an appropriate limit enables the load balancer to start new session hosts before existing ones become overloaded."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-host-pool-load-balancing

---

### CATEGORY: Reliability & Resilience

---

#### CHECK 5: Session Host Health Overview

**What it checks:** Whether all session hosts are in a healthy state (Available or intentionally Shutdown).

**How to detect:**
- Flag any session host where `$host.Status` is NOT in `@('Available', 'Shutdown')`
- Group unhealthy hosts by status for the finding message

**Pass:** All session hosts are in a healthy state.  
**Fail:** One or more session hosts are in an unhealthy state.  
**Info:** No session hosts found.

`Score (Fail): percentage of healthy hosts (e.g. 8/10 healthy = 80)`

**Finding (Fail):** Include count, percentage, and a breakdown by status (e.g. "2 Unavailable, 1 NeedsAssistance").

**Remediation (Fail):** "Investigate unhealthy session hosts using AVD Insights in the Azure portal (if diagnostic settings are configured) or by reviewing the AVD agent log directly on the affected VM at C:\Program Files\Microsoft RDAgent\. Common causes: domain trust relationship lost, FSLogix health failures, AVD agent crash, or underlying VM disk/network issues. Consider enabling AVD health alerts via Azure Monitor."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/troubleshoot-session-host-in-use

---

#### CHECK 6: RDP Shortpath / Network Auto-Detect Configuration

**What it checks:** Whether host pools have network auto-detection RDP properties configured, which is a prerequisite for RDP Shortpath (UDP) to function — providing lower latency and better session resilience than TCP Reverse Connect.

**How to detect:**
- Examine `$hp.CustomRdpProperty` string for each host pool
- Check for presence of `networkautodetect:i:1` or `bandwidthautodetect:i:1`

Helper function to parse RDP properties:
```powershell
function Get-RdpProperty {
    param([string]$RdpString, [string]$PropertyName)
    if ([string]::IsNullOrEmpty($RdpString)) { return $null }
    $match = $RdpString -split ';' | Where-Object { $_ -match "^$([regex]::Escape($PropertyName)):" }
    if ($match) { return ($match -split ':')[2] }
    return $null
}
```

**Pass:** All host pools have network auto-detect properties explicitly configured.  
**Warning:** One or more host pools are missing explicit network auto-detect configuration.

`Score (Warning): 50`

**Remediation (Warning):** "Add networkautodetect:i:1 and bandwidthautodetect:i:1 to the Custom RDP Properties of each host pool. These settings enable RDP Shortpath (UDP), which provides significantly lower latency, better audio/video quality, and improved session resilience compared to the TCP Reverse Connect fallback. Also ensure UDP port 3478 (STUN) is permitted outbound at the firewall for public network Shortpath."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath

---

#### CHECK 7: Agent Update Ring Configuration

**What it checks:** Whether the environment has a healthy split between validation ring and production ring host pools — at least one pool on validation for early testing, but not all production pools on validation.

**How to detect:**
- Count host pools where `$hp.ValidationEnvironment -eq $true`
- Evaluate three conditions: none on validation, all on validation, or good mix

**Pass:** At least one (but not all) host pools are on the validation ring.  
`Finding: "N host pool(s) are in Validation ring, M are in production ring. Good separation."`

**Warning (no validation):** No host pools are on the validation ring. The environment has no early warning system for AVD agent updates.  
`Score: 70`

**Warning (all validation):** All host pools are on the validation ring. Production users are receiving pre-release agent updates which may introduce instability.  
`Score: 40`

**Remediation (no validation):** "Mark at least one non-production or low-risk host pool as a Validation environment in its properties. Validation ring pools receive AVD agent updates 1–2 weeks before the production ring, giving you an early warning of any issues before they affect all users."

**Remediation (all validation):** "Move your production host pools off the Validation ring. Only canary, dev, or test host pools should be in Validation. Production users should be on the standard update ring for maximum stability."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-validation-environment

---

#### CHECK 8: Session Capacity Headroom

**What it checks:** Whether pooled host pools are running close to their maximum session capacity, leaving no headroom for demand spikes.

**How to detect:**
- For each pooled host pool, sum the `Sessions` property across all session hosts in that pool
- Calculate: `totalSessions / (MaxSessionLimit × sessionHostCount)`
- Flag if utilisation > 85%

**Pass:** All host pools are below 85% session capacity.  
**Warning:** One or more pools are above 85% capacity.

`Score (Warning): 30` | List affected pools.

**Remediation (Warning):** "Add session hosts to the over-capacity pool(s), or review whether the max session limit is set too high relative to available VM resources. Also review the scaling plan ramp-up schedule to ensure hosts are started before peak demand rather than in response to it — proactive scaling prevents the headroom problem entirely."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan

---

### CATEGORY: Security Posture

---

#### CHECK 9: Drive Redirection Policy

**What it checks:** Whether host pools allow broad local drive redirection, which is a potential data exfiltration vector (users can copy files to/from local drives during remote sessions).

**How to detect:**
- Parse `CustomRdpProperty` for each host pool using `Get-RdpProperty`
- Get value of `drivestoredirect`
- Flag as risky if value is `*` (all drives) OR if the property is absent entirely (default in many cases is enabled)

**Pass:** Drive redirection is explicitly restricted on all host pools.  
**Warning:** One or more host pools have broad drive redirection enabled or at an unreviewed default.

`Score (Warning): 40`

**Remediation (Warning):** "Review the drivestoredirect RDP property on each flagged host pool. Set drivestoredirect:s: (empty value) to disable drive redirection entirely, or drivestoredirect:s:DynamicDrives to allow only removable drives (USB). In regulated environments (financial services, healthcare, government), drive redirection should be explicitly disabled unless a business case exists and it is documented."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties

---

#### CHECK 10: Clipboard Redirection Policy

**What it checks:** Whether clipboard redirection has been explicitly reviewed and configured, rather than left at the default (enabled). Clipboard redirection allows copy/paste between the local device and the remote session, which is a data transfer risk in sensitive environments.

**How to detect:**
- Parse `CustomRdpProperty` for `redirectclipboard`
- Flag as informational if value is `1` or absent (default = enabled)
- Only Pass if explicitly set to `0`

**Status:** This check returns `Info` rather than `Warning` or `Fail` because clipboard is a legitimate productivity requirement in most environments. The intent is to surface it for a conscious decision, not to penalise.

**Finding (Info):** "N host pool(s) have clipboard redirection enabled (or at default). This is common but should be a deliberate decision."

**Remediation:** "If clipboard access is not required for user productivity or is prohibited by your data security policy, set redirectclipboard:i:0 in host pool RDP properties. This is particularly important for environments handling sensitive personal or financial data where copy/paste to local devices would represent a compliance risk."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties

---

#### CHECK 11: Trusted Launch / Secure Boot

**What it checks:** Whether session host VMs are configured with Trusted Launch (Secure Boot + vTPM), which protects against boot-level attacks and rootkit injection.

**How to detect:**
- For each AVD session host VM in `$allVMs`, check `$vm.SecurityProfile.SecurityType`
- Pass if `SecurityType -eq 'TrustedLaunch'`
- Warn if `SecurityType` is null or different

**Pass:** All session host VMs are using Trusted Launch.  
**Warning:** One or more session host VMs are not using Trusted Launch.  
**Info:** No VMs found.

`Score (Warning): proportional — e.g. 3/5 using Trusted Launch = 60`

**Remediation (Warning):** "New session host deployments should use Trusted Launch (enabled by default for Gen2 VMs in Azure). For existing VMs, Microsoft now supports migration to Trusted Launch for Gen2 VMs without redeployment. See the Learn More link for the migration process. Trusted Launch enables Secure Boot (prevents unsigned bootloaders and drivers) and vTPM (supports attestation and BitLocker)."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-existing-vm

---

#### CHECK 12: Entra ID Join Status

**What it checks:** Whether session hosts are Entra ID joined (cloud-native, preferred) versus hybrid-joined or domain-joined only. Entra ID join removes the dependency on on-premises domain controllers and is the recommended architecture for new AVD deployments.

**How to detect:**
- For each VM in `$allVMs`, check for the presence of the `AADLoginForWindows` extension in `$vm.Extensions`
- Entra-joined VMs will have this extension; hybrid/domain-joined VMs will not

**Pass:** All session host VMs appear to be Entra ID joined.  
**Info:** Some session hosts appear to be hybrid or domain-joined only. (Use Info, not Fail — hybrid join is a valid and common configuration, especially for legacy application compatibility.)

`Score (Info): 100` (excluded from average, informational only)

**Finding (Info):** "N of M session host VM(s) appear to be hybrid-joined or domain-joined only (AADLoginForWindows extension not detected). Entra ID join is the recommended approach for new AVD deployments."

**Remediation:** "Evaluate migrating new host pool deployments to Entra ID join. This eliminates line-of-sight dependency on domain controllers, simplifies the identity architecture, and enables Conditional Access at the session level. Note: FSLogix profiles, MSIX App Attach, and some legacy applications may require additional planning for Entra ID join scenarios."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-ad-joined-vm

---

### CATEGORY: Operational Excellence

---

#### CHECK 13: Diagnostic Settings

**What it checks:** Whether host pools have diagnostic settings configured to send logs to a Log Analytics workspace. Without this, AVD Insights does not function and troubleshooting connectivity, session, or performance issues is severely limited.

**How to detect:**
- For each host pool, call `Get-AzDiagnosticSetting -ResourceId $hp.Id`
- Pass if at least one diagnostic setting is returned with a Log Analytics workspace configured

**Pass:** All host pools have diagnostic settings configured.  
**Fail:** One or more host pools have no diagnostic settings.  
**Info:** No host pools found.

`Score (Fail): proportional`

**Remediation (Fail):** "Configure diagnostic settings on each flagged host pool to send the following log categories to a Log Analytics workspace: Connection, HostRegistration, Error, Management, AgentHealthStatus. This is a prerequisite for AVD Insights and enables troubleshooting of connection failures, performance issues, and agent problems. Without diagnostic logs, you are flying blind."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics

---

#### CHECK 14: Resource Tagging

**What it checks:** Whether host pools have the minimum required tags (Environment and Owner) to support cost attribution and governance.

**How to detect:**
- For each host pool, call `Get-AzResource -ResourceId $hp.Id`
- Check for presence of `Environment` and `Owner` keys in `$resource.Tags`
- Flag any that are missing either tag

**Pass:** All host pools have both required tags.  
**Warning:** One or more host pools are missing required tags.

`Score (Warning): proportional`

**Remediation (Warning):** "Apply the following tags to all AVD resources (host pools, session hosts, workspaces, storage accounts): Environment (e.g. Production, Development, Test) and Owner (team or person responsible). Consider using Azure Policy with a DeployIfNotExists or Deny effect to enforce tagging at resource creation. Good tagging enables cost analysis by environment in Azure Cost Management."

**Learn More:** https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources

---

#### CHECK 15: AVD Agent Update State

**What it checks:** Whether any session hosts have a failed or stalled AVD agent update. Agent failures can cause session hosts to become unresponsive, lose connectivity, or stop receiving new connections.

**How to detect:**
- For each session host, check `$host.UpdateState`
- Flag if `UpdateState -eq 'Failed'` or `UpdateState -eq 'Stalled'`

**Pass:** All session hosts have a healthy agent update state.  
**Fail:** One or more session hosts have a Failed or Stalled agent update.  
**Info:** No session hosts found.

`Score (Fail): proportional`

**Remediation (Fail):** "Investigate agent update failures on the affected session hosts. Start by reviewing the RDAgent log at C:\Program Files\Microsoft RDAgent\AgentInstall.txt. Common causes: Windows Update failing to install prerequisites, a network proxy blocking the agent download endpoint (*.wvd.microsoft.com), antivirus blocking the installer, or the VM needing a restart. After resolving, restart the RDAgentBootLoader service to retry the update."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/troubleshoot-agent

---

#### CHECK 16: Load Balancing Algorithm

**What it checks:** Whether pooled host pools have a deliberate load balancing configuration. Both BreadthFirst and DepthFirst are valid choices with different trade-offs — this check is informational and educational, not a pass/fail assessment.

**How to detect:**
- For each pooled host pool, read `$hp.LoadBalancerType`
- Count BreadthFirst vs DepthFirst pools
- Always return Pass with an informational summary

**Status:** Always `Pass` (informational review, not a failure condition).

**Finding:** "Load balancing review: N pool(s) use BreadthFirst (performance-optimised — spreads users across more VMs), M pool(s) use DepthFirst (cost-optimised — fills VMs before starting new ones)."

**Remediation / Guidance:** "BreadthFirst is recommended when user experience is the top priority — each user gets more dedicated resources. DepthFirst is recommended when cost is the priority and the workload is not resource-intensive — it allows more VMs to be fully shut down during off-peak hours. Review your choice against your scaling plan configuration: DepthFirst works best with aggressive scale-in, BreadthFirst pairs well with reserved instances on a core set of always-on hosts."

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-host-pool-load-balancing

---

## 9. HTML Report Design

The report is a self-contained single HTML file (no external dependencies except Google Fonts CDN). It should be professional enough to share with a customer or senior stakeholder.

### Colour palette (Wayne's personal brand)

| Token | Hex | Usage |
|---|---|---|
| Background deep | `#0a1f2e` | Page background |
| Background card | `#0D2535` | Cards, header |
| Background surface | `#1a3547` | Card borders, dividers |
| Lime green | `#B3FF00` | Pass state, accent, score values when high |
| Teal | `#33CCCC` | Info state, links, secondary accent |
| Amber | `#f59e0b` | Warning state |
| Red | `#ef4444` | Fail state |
| Green | `#22c55e` | Pass state in traffic lights |
| White | `#ffffff` | Primary text |
| Muted | `#94a3b8` | Secondary text, metadata |
| Dim | `#64748b` | Tertiary text |

**Font:** Inter from Google Fonts (`https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap`)

### Report layout

```
┌─────────────────────────────────────────────────────────────────┐
│ HEADER: "AVD-Assess" logo + overall score donut + score number  │
├─────────────────────────────────────────────────────────────────┤
│ META BAR: Subscription | Tenant | Host Pools | Hosts | Date     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────┐  ┌──────────────────────┐           │
│  │  Cost Optimisation   │  │ Reliability & Resi.. │           │
│  │  [donut] 72/100      │  │  [donut] 85/100      │           │
│  │  ─────────────────── │  │  ─────────────────── │           │
│  │  ✓ Scaling Plans     │  │  ✓ Host Health       │           │
│  │  ✗ Start VM Connect  │  │  ⚠ RDP Shortpath     │           │
│  │  ✓ Unhealthy Hosts   │  │  ✓ Agent Ring        │           │
│  │  ⚠ Max Session Limit │  │  ✓ Capacity          │           │
│  └──────────────────────┘  └──────────────────────┘           │
│                                                                 │
│  ┌──────────────────────┐  ┌──────────────────────┐           │
│  │  Security Posture    │  │ Operational Excell.. │           │
│  └──────────────────────┘  └──────────────────────┘           │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ FOOTER: AVD-Assess v1.0.0 · modern-euc.com · github link       │
└─────────────────────────────────────────────────────────────────┘
```

### Interaction

Every check row is **clickable to expand**. Collapsed state shows: check name + status badge. Expanded state shows: finding text + remediation text (styled differently, blue-tinted box with left border in teal) + Learn More link if present.

Use pure CSS for the toggle (`.check-row.expanded .check-detail { display: block; }`) via JavaScript `onclick="this.classList.toggle('expanded')"`.

### Score donut charts

Use inline SVG with a stroke-dasharray circle. Two concentric circles: one for the track (dark fill), one animated stroke for the score arc. Show the numeric score in the centre.

```
Radius: 54px | ViewBox: 130×130 | Stroke width: 12px
Circumference: 2π × 54 ≈ 339.3
Dash: (score/100) × circumference
Gap: circumference - dash
Rotate: -90deg (start from top)
```

### Status badges

Inline `<span>` elements with pill styling (border-radius: 12px, small font, coloured border and background at 10–20% opacity):

- ✓ Pass → green (`#22c55e`)
- ⚠ Warning → amber (`#f59e0b`)
- ✗ Fail → red (`#ef4444`)
- ℹ Info → teal (`#33CCCC`)

---

## 10. Console Output

The script should produce clean, readable console output as it runs:

```
  ╔══════════════════════════════════════════╗
  ║         AVD-Assess  v1.0.0               ║
  ║  Azure Virtual Desktop Health Checker    ║
  ║  modern-euc.com | github.com/wbellows   ║
  ╚══════════════════════════════════════════╝

  Connecting to Azure
  ──────────────────
  Subscription : Contoso Production (xxxxxxxx-...)
  Tenant       : xxxxxxxx-...

  Collecting environment data
  ───────────────────────────
  Fetching host pools...     Found 5 host pool(s)
  Fetching session hosts...  Found 47 session host(s)
  Fetching scaling plans...  Found 3 scaling plan(s)
  Fetching virtual machines... Found 47 AVD virtual machine(s)
  Fetching diagnostic settings...

  Cost Optimisation
  ─────────────────
  [PASS] Scaling Plan Coverage
  [FAIL] Start VM on Connect (Personal)
  [PASS] Unhealthy Hosts in Session Rotation
  [WARN] Max Session Limit Configuration

  Reliability & Resilience
  ────────────────────────
  [PASS] Session Host Health
  [WARN] RDP Shortpath Configuration
  [PASS] Agent Update Ring
  [PASS] Session Capacity Headroom

  ... (etc)

  Score Summary
  ─────────────
  Cost Optimisation:      72/100
  Reliability:            85/100
  Security Posture:       68/100
  Operational Excellence: 90/100

  Overall Score: 79/100

  ✅ Report saved to: C:\Reports\AVD-Assess-Report-20260424-143022.html
```

Colour the `[PASS]` lines green, `[WARN]` amber, `[FAIL]` red in the console using `Write-Host -ForegroundColor`.

---

## 11. Error Handling Guidelines

- Use `$ErrorActionPreference = 'Stop'` at the top, but wrap individual data collection calls in `try/catch`
- If a module is missing, output a clear error: "Required module Az.DesktopVirtualization not found. Run: Install-Module Az.DesktopVirtualization -Scope CurrentUser"
- If the user has no host pools, output a friendly message and exit cleanly
- If a specific resource query fails (e.g. insufficient permissions for VMs), set the affected checks to `Info` with a finding like "Unable to retrieve VM data — Reader permissions may be missing on the compute resources. Skipping VM-related checks."
- Never crash silently — all errors should produce a human-readable explanation

---

## 12. README Requirements

The README.md should include:

1. **Project headline** — one sentence describing what it does
2. **Why this exists** — the gap it fills
3. **Screenshot placeholder** — `![AVD-Assess Report](docs/screenshot.png)` (screenshot to be added after first run)
4. **Prerequisites** — PowerShell 7+, Az modules, Reader permission
5. **Quick start** — install modules → clone/download → run
6. **Parameters table** — all parameters with description and example
7. **Check categories** — brief description of each category (not all 16 checks, just the 4 categories with a bullet or two)
8. **Permissions required** — Reader on the subscription (or narrower scope: Desktop Virtualization Reader + Reader on compute)
9. **Contributing** — link to CONTRIBUTING.md
10. **License** — MIT

**Install command to include in README:**
```powershell
# Install required modules (one-time)
Install-Module Az.Accounts, Az.DesktopVirtualization, Az.Compute, Az.Monitor, Az.Resources -Scope CurrentUser

# Clone the repo
git clone https://github.com/wbellows/AVD-Assess.git
cd AVD-Assess

# Run against your current Azure context
.\AVD-Assess.ps1 -OpenReport
```

---

## 13. CONTRIBUTING.md Requirements

Keep it simple:

- How to add a new check (call `Add-CheckResult` with the right parameters, follow the data model)
- How to test (run against a test subscription with varied configurations)
- PR guidelines (one check per PR, include test evidence)
- Code style (comment all checks clearly, use `$ErrorActionPreference` safe patterns)

---

## 14. Out of Scope for v1.0

The following are explicitly out of scope for the initial build. Do not implement these:

- FSLogix configuration checks (requires registry access on session hosts)
- Network Security Group rule analysis (requires RBAC on networking resources)
- Reserved Instance coverage analysis (requires Billing Reader role)
- Multi-subscription sweep (v1 is single subscription)
- JSON or CSV output mode (HTML only for v1)
- Parallel check execution
- CI/CD pipeline integration mode
- Azure Lighthouse support
- Any GUI or web interface

---

## 15. Delivery Checklist

When the build is complete, verify the following:

- [ ] Script runs without errors against a subscription with at least one host pool
- [ ] Script exits gracefully if there are no host pools
- [ ] Script handles missing permissions gracefully (no unhandled exceptions)
- [ ] All 16 checks are implemented and produce output
- [ ] HTML report opens correctly in Edge, Chrome, and Firefox
- [ ] All clickable check rows expand and collapse correctly
- [ ] Donut charts render correctly for scores 0, 50, and 100
- [ ] Report is fully self-contained (works offline, except Google Fonts)
- [ ] Console output is clean and readable with correct colours
- [ ] README includes quick-start instructions
- [ ] MIT license file is present
- [ ] `.gitignore` covers common PowerShell and Windows artefacts

---

*This specification was prepared to support the build of AVD-Assess v1.0.0. Questions or clarifications: wbellows@getnerdio.com*
