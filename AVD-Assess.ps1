<#
.SYNOPSIS
    AVD-Assess - Azure Virtual Desktop health checker.

.DESCRIPTION
    Connects to an Azure subscription, runs 16 best-practice checks against Azure
    Virtual Desktop (AVD) host pools, session hosts, scaling plans, and related
    resources, and produces a self-contained HTML report with traffic-light
    scoring and remediation guidance across Cost, Reliability, Security, and
    Operational Excellence.

.PARAMETER SubscriptionId
    Azure subscription ID to assess. If not provided, uses the current Az context.

.PARAMETER TenantId
    Azure tenant ID. If not provided, uses the current Az context.

.PARAMETER OutputPath
    Where to save the HTML report. Defaults to the current directory with a
    timestamped filename: AVD-Assess-Report-yyyyMMdd-HHmmss.html

.PARAMETER HostPoolName
    Optional: scope the assessment to a single host pool by name.
    Must be used with -ResourceGroupName.

.PARAMETER ResourceGroupName
    Optional: scope the assessment to a specific resource group.

.PARAMETER UseExistingConnection
    Skip Connect-AzAccount and use the existing Az PowerShell context.

.PARAMETER OpenReport
    Open the HTML report in the default browser when complete.

.PARAMETER DryRun
    Generate a report using synthetic data - no Azure calls are made. Used for
    HTML layout verification and for contributors testing UI changes.

.EXAMPLE
    .\AVD-Assess.ps1
    Run against all host pools in the current Az context.

.EXAMPLE
    .\AVD-Assess.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -OpenReport

.EXAMPLE
    .\AVD-Assess.ps1 -HostPoolName "hp-prod-pooled-01" -ResourceGroupName "rg-avd-prod"

.EXAMPLE
    .\AVD-Assess.ps1 -UseExistingConnection -OutputPath "C:\Reports\avd-health.html"

.NOTES
    Author   : Wayne Bellows (wayne_bellows@hotmail.com)
    Website  : https://modern-euc.com
    Project  : https://github.com/waynebellows/AVD-Assess
    License  : MIT
    Version  : 1.0.0
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$OutputPath,
    [string]$HostPoolName,
    [string]$ResourceGroupName,
    [switch]$UseExistingConnection,
    [switch]$OpenReport,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$script:ToolVersion = '1.0.0'
$script:ProjectUrl  = 'https://github.com/waynebellows/AVD-Assess'
$script:WebsiteUrl  = 'https://modern-euc.com'
$script:RequiredModules = @(
    'Az.Accounts',
    'Az.DesktopVirtualization',
    'Az.Compute',
    'Az.Monitor',
    'Az.Resources'
)

# ==============================================================================
# CHECK CATALOG
# ==============================================================================
#
# Single source of truth for each check's display name, canonical remediation
# text, and Microsoft Learn URL. Read by both the real check functions and the
# dry-run seeder so the two stay in sync.
#
# Special-case remediations (e.g. "Grant Reader role…" when a permission fetch
# fails) are kept inline at the call site rather than catalogued, because they
# describe *why* a fetch failed and aren't part of the check's primary advice.

$script:CheckCatalog = @{

    # ---- Cost Optimisation ----
    ScalingPlanCoverage = [PSCustomObject]@{
        Name        = 'Scaling Plan Coverage'
        Remediation = 'Create and assign a scaling plan to each pooled host pool. Scaling plans can reduce Azure compute costs by 40-70% for environments with predictable daily usage patterns by automatically deallocating idle session hosts outside peak hours.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan'
    }

    StartVmOnConnect = [PSCustomObject]@{
        Name        = 'Start VM on Connect (Personal Host Pools)'
        Remediation = 'Enable Start VM on Connect on all personal host pools. This ensures personal VMs are only running when users need them, rather than 24/7. Combine with an auto-shutdown schedule for maximum savings. A personal VM running 24/7 costs approximately 3x more than one using Start VM on Connect with an 8-hour working day pattern.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/start-virtual-machine-connect'
    }

    UnhealthyHostsInRotation = [PSCustomObject]@{
        Name        = 'Unhealthy Hosts in Session Rotation'
        Remediation = 'Set AllowNewSession = false on unhealthy hosts to drain them from the load balancer. This prevents new users from connecting to broken session hosts. Investigate the underlying health issue (check AVD agent logs at C:\Program Files\Microsoft RDAgent\) and either remediate the VM or replace the session host.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/drain-mode'
    }

    MaxSessionLimit = [PSCustomObject]@{
        Name        = 'Max Session Limit Configuration'
        Remediation = 'Set a realistic max session limit based on your VM size and workload type. Recommended starting points: D4s_v5 (4 vCPU / 16 GB) - 8-12 sessions for knowledge workers, 12-16 for task workers. D8s_v5 (8 vCPU / 32 GB) - 16-24 sessions for knowledge workers. Setting an appropriate limit enables the load balancer to start new session hosts before existing ones become overloaded.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-host-pool-load-balancing'
    }

    # ---- Reliability & Resilience ----
    SessionHostHealth = [PSCustomObject]@{
        Name        = 'Session Host Health'
        Remediation = 'Investigate unhealthy session hosts using AVD Insights in the Azure portal (if diagnostic settings are configured) or by reviewing the AVD agent log directly on the affected VM at C:\Program Files\Microsoft RDAgent\. Common causes: domain trust relationship lost, FSLogix health failures, AVD agent crash, or underlying VM disk/network issues. Consider enabling AVD health alerts via Azure Monitor.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/troubleshoot-session-host-in-use'
    }

    RdpShortpath = [PSCustomObject]@{
        Name        = 'RDP Shortpath / Network Auto-Detect'
        Remediation = 'Add networkautodetect:i:1 and bandwidthautodetect:i:1 to the Custom RDP Properties of each host pool. These settings enable RDP Shortpath (UDP), which provides significantly lower latency, better audio/video quality, and improved session resilience compared to the TCP Reverse Connect fallback. Also ensure UDP port 3478 (STUN) is permitted outbound at the firewall for public network Shortpath.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-shortpath'
    }

    AgentUpdateRing = [PSCustomObject]@{
        Name                       = 'Agent Update Ring'
        # Default to the more common case (no validation pools); the real check
        # function picks RemediationAllValidation when every pool is on validation.
        Remediation                = 'Mark at least one non-production or low-risk host pool as a Validation environment in its properties. Validation ring pools receive AVD agent updates 1-2 weeks before the production ring, giving you an early warning of any issues before they affect all users.'
        RemediationAllValidation   = 'Move your production host pools off the Validation ring. Only canary, dev, or test host pools should be in Validation. Production users should be on the standard update ring for maximum stability.'
        LearnMore                  = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-validation-environment'
    }

    SessionCapacityHeadroom = [PSCustomObject]@{
        Name        = 'Session Capacity Headroom'
        Remediation = 'Add session hosts to the over-capacity pool(s), or review whether the max session limit is set too high relative to available VM resources. Also review the scaling plan ramp-up schedule to ensure hosts are started before peak demand rather than in response to it - proactive scaling prevents the headroom problem entirely.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/autoscale-scaling-plan'
    }

    # ---- Security Posture ----
    DriveRedirection = [PSCustomObject]@{
        Name        = 'Drive Redirection Policy'
        Remediation = 'Review the drivestoredirect RDP property on each flagged host pool. Set drivestoredirect:s: (empty value) to disable drive redirection entirely, or drivestoredirect:s:DynamicDrives to allow only removable drives (USB). In regulated environments (financial services, healthcare, government), drive redirection should be explicitly disabled unless a business case exists and it is documented.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties'
    }

    ClipboardRedirection = [PSCustomObject]@{
        Name        = 'Clipboard Redirection Policy'
        Remediation = 'If clipboard access is not required for user productivity or is prohibited by your data security policy, set redirectclipboard:i:0 in host pool RDP properties. This is particularly important for environments handling sensitive personal or financial data where copy/paste to local devices would represent a compliance risk.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties'
    }

    TrustedLaunch = [PSCustomObject]@{
        Name        = 'Trusted Launch / Secure Boot'
        Remediation = 'New session host deployments should use Trusted Launch (enabled by default for Gen2 VMs in Azure). For existing VMs, Microsoft now supports migration to Trusted Launch for Gen2 VMs without redeployment. See the Learn More link for the migration process. Trusted Launch enables Secure Boot (prevents unsigned bootloaders and drivers) and vTPM (supports attestation and BitLocker).'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-existing-vm'
    }

    EntraIdJoin = [PSCustomObject]@{
        Name        = 'Entra ID Join Status'
        Remediation = 'Evaluate migrating new host pool deployments to Entra ID join. This eliminates line-of-sight dependency on domain controllers, simplifies the identity architecture, and enables Conditional Access at the session level. Note: FSLogix profiles, MSIX App Attach, and some legacy applications may require additional planning for Entra ID join scenarios.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/deploy-azure-ad-joined-vm'
    }

    # ---- Operational Excellence ----
    DiagnosticSettings = [PSCustomObject]@{
        Name        = 'Diagnostic Settings'
        Remediation = 'Configure diagnostic settings on each flagged host pool to send the following log categories to a Log Analytics workspace: Connection, HostRegistration, Error, Management, AgentHealthStatus. This is a prerequisite for AVD Insights and enables troubleshooting of connection failures, performance issues, and agent problems. Without diagnostic logs, you are flying blind.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/diagnostics-log-analytics'
    }

    ResourceTagging = [PSCustomObject]@{
        Name        = 'Resource Tagging'
        Remediation = 'Apply the following tags to all AVD resources (host pools, session hosts, workspaces, storage accounts): Environment (e.g. Production, Development, Test) and Owner (team or person responsible). Consider using Azure Policy with a DeployIfNotExists or Deny effect to enforce tagging at resource creation. Good tagging enables cost analysis by environment in Azure Cost Management.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources'
    }

    AgentUpdateState = [PSCustomObject]@{
        Name        = 'AVD Agent Update State'
        Remediation = 'Investigate agent update failures on the affected session hosts. Start by reviewing the RDAgent log at C:\Program Files\Microsoft RDAgent\AgentInstall.txt. Common causes: Windows Update failing to install prerequisites, a network proxy blocking the agent download endpoint (*.wvd.microsoft.com), antivirus blocking the installer, or the VM needing a restart. After resolving, restart the RDAgentBootLoader service to retry the update.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/troubleshoot-agent'
    }

    LoadBalancingAlgorithm = [PSCustomObject]@{
        Name        = 'Load Balancing Algorithm'
        Remediation = 'BreadthFirst is recommended when user experience is the top priority - each user gets more dedicated resources. DepthFirst is recommended when cost is the priority and the workload is not resource-intensive - it allows more VMs to be fully shut down during off-peak hours. Review your choice against your scaling plan configuration: DepthFirst works best with aggressive scale-in, BreadthFirst pairs well with reserved instances on a core set of always-on hosts.'
        LearnMore   = 'https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-host-pool-load-balancing'
    }
}

function Get-Check {
    # Returns the catalog entry for a check ID. Throws on unknown IDs so typos
    # surface immediately rather than producing reports with blank fields.
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:CheckCatalog.ContainsKey($Id)) {
        throw "Unknown check ID '$Id'. Catalog keys: $(($script:CheckCatalog.Keys | Sort-Object) -join ', ')"
    }
    return $script:CheckCatalog[$Id]
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

$script:Checks = [System.Collections.Generic.List[object]]::new()

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Cost','Reliability','Security','Operations')]
        [string]$Category,
        [Parameter(Mandatory)][string]$CheckName,
        [Parameter(Mandatory)][ValidateSet('Pass','Warning','Fail','Info')]
        [string]$Status,
        [Parameter(Mandatory)][ValidateRange(0,100)][int]$Score,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Finding,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Remediation,
        [AllowEmptyString()][string]$LearnMore = ''
    )
    $script:Checks.Add([PSCustomObject]@{
        Category    = $Category
        CheckName   = $CheckName
        Status      = $Status
        Score       = $Score
        Finding     = $Finding
        Remediation = $Remediation
        LearnMore   = $LearnMore
    })

    $colour = switch ($Status) {
        'Pass'    { 'Green' }
        'Warning' { 'Yellow' }
        'Fail'    { 'Red' }
        'Info'    { 'Cyan' }
    }
    $tag = switch ($Status) {
        'Pass'    { '[PASS]' }
        'Warning' { '[WARN]' }
        'Fail'    { '[FAIL]' }
        'Info'    { '[INFO]' }
    }
    Write-Host ('  {0} {1}' -f $tag, $CheckName) -ForegroundColor $colour
}

function Write-Section {
    param([string]$Title)
    $underline = '-' * $Title.Length
    Write-Host ''
    Write-Host "  $Title"      -ForegroundColor White
    Write-Host "  $underline" -ForegroundColor DarkGray
}

function Write-Banner {
    $v = $script:ToolVersion
    $verLine = "  |           AVD-Assess  v{0,-22}|" -f $v
    Write-Host ''
    Write-Host '  +----------------------------------------------+' -ForegroundColor Cyan
    Write-Host $verLine                                              -ForegroundColor Cyan
    Write-Host '  |  Azure Virtual Desktop Health Checker        |' -ForegroundColor Cyan
    Write-Host '  |  modern-euc.com                              |' -ForegroundColor Cyan
    Write-Host '  |  github.com/waynebellows/AVD-Assess          |' -ForegroundColor Cyan
    Write-Host '  +----------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
}

function Get-RdpProperty {
    param([string]$RdpString, [string]$PropertyName)
    if ([string]::IsNullOrEmpty($RdpString)) { return $null }
    $match = $RdpString -split ';' | Where-Object { $_ -match "^$([regex]::Escape($PropertyName)):" }
    if ($match) {
        $parts = $match -split ':', 3
        if ($parts.Count -ge 3) { return $parts[2] }
    }
    return $null
}

function Get-RgFromArmId {
    # Extracts the resource group name from an ARM resource ID. ARM IDs have the
    # shape: /subscriptions/<sub>/resourceGroups/<rg>/providers/<...>
    param([Parameter(Mandatory)][string]$ResourceId)
    $parts = $ResourceId -split '/'
    if ($parts.Count -ge 5) { return $parts[4] }
    throw "Cannot extract resource group from ARM ID: $ResourceId"
}

function Invoke-WithRetry {
    # Wraps a scriptblock in a small retry loop with exponential backoff. Retries
    # on transient ARM throttling (HTTP 429) and gateway timeouts; surfaces other
    # errors immediately so genuine failures still throw quickly.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2,
        [string]$OperationName = 'Azure operation'
    )
    $attempt = 0
    $delay   = $InitialDelaySeconds
    while ($true) {
        $attempt++
        try {
            return & $ScriptBlock
        } catch {
            $msg = $_.Exception.Message
            $isTransient = $msg -match '\b(429|TooManyRequests|throttl|timeout|GatewayTimeout|ServiceUnavailable|503)\b'
            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                throw
            }
            Write-Verbose "$OperationName attempt $attempt failed (transient): $msg. Retrying in $delay s."
            Start-Sleep -Seconds $delay
            $delay = [math]::Min($delay * 2, 30)
        }
    }
}

function Get-ScoreColour {
    param([int]$Score)
    if ($Score -ge 80) { return '#B3FF00' }  # lime green
    elseif ($Score -ge 60) { return '#33CCCC' }  # teal
    elseif ($Score -ge 40) { return '#f59e0b' }  # amber
    else { return '#ef4444' }                    # red
}

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text `
        -replace '&', '&amp;' `
        -replace '<', '&lt;' `
        -replace '>', '&gt;' `
        -replace '"', '&quot;' `
        -replace "'", '&#39;'
}

function New-DonutSvg {
    param([int]$Score, [int]$Size = 130)
    $circumference = [math]::Round(2 * [math]::PI * 54, 3)
    $dash = [math]::Round(($Score / 100.0) * $circumference, 3)
    $gap  = [math]::Round($circumference - $dash, 3)
    $colour = Get-ScoreColour -Score $Score
    $fontSize = if ($Size -ge 130) { 28 } else { 22 }
    return @"
<svg viewBox="0 0 130 130" width="$Size" height="$Size" class="donut" role="img" aria-label="Score $Score out of 100">
  <circle cx="65" cy="65" r="54" fill="none" stroke="#1a3547" stroke-width="12"/>
  <circle cx="65" cy="65" r="54" fill="none" stroke="$colour" stroke-width="12"
          stroke-dasharray="$dash $gap"
          transform="rotate(-90 65 65)"
          stroke-linecap="round"/>
  <text x="65" y="73" text-anchor="middle" fill="#ffffff" font-size="$fontSize" font-weight="700" font-family="Inter, system-ui, sans-serif">$Score</text>
</svg>
"@
}

function Get-StatusClass {
    param([string]$Status)
    switch ($Status) {
        'Pass'    { 'pass' }
        'Warning' { 'warn' }
        'Fail'    { 'fail' }
        'Info'    { 'info' }
    }
}

function Get-StatusSymbol {
    param([string]$Status)
    switch ($Status) {
        'Pass'    { "&#10003; Pass" }      # ✓
        'Warning' { "&#9888; Warning" }    # ⚠
        'Fail'    { "&#10007; Fail" }      # ✗
        'Info'    { "&#9432; Info" }       # ⓘ
    }
}

function Assert-RequiredModules {
    $missing = @()
    foreach ($mod in $script:RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host '  ERROR: Required PowerShell module(s) not installed:' -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "    - $m" -ForegroundColor Red }
        Write-Host ''
        Write-Host '  Install with:' -ForegroundColor Yellow
        Write-Host ("    Install-Module {0} -Scope CurrentUser" -f ($missing -join ', ')) -ForegroundColor Yellow
        Write-Host ''
        throw 'Missing required modules.'
    }
    foreach ($mod in $script:RequiredModules) {
        Import-Module $mod -ErrorAction Stop | Out-Null
    }
}

# ==============================================================================
# DRY-RUN SEEDER (hidden; for HTML layout verification only)
# ==============================================================================

function Initialize-DryRunData {
    Write-Host ''
    Write-Host '  [DryRun] Seeding synthetic data. No Azure calls will be made.' -ForegroundColor Cyan

    $script:Context = [PSCustomObject]@{
        SubscriptionName = 'Contoso Production (DryRun)'
        SubscriptionId   = '00000000-0000-0000-0000-000000000000'
        TenantId         = '11111111-1111-1111-1111-111111111111'
    }
    $script:HostPoolCount    = 5
    $script:SessionHostCount = 47
    $script:ScalingPlanCount = 3
    $script:VmCount          = 47

    # Each entry below seeds one synthetic check result. Name / Remediation /
    # LearnMore come from $script:CheckCatalog so the dry-run report stays in
    # lock-step with the canonical text used by the real check functions.

    Write-Section 'Cost Optimisation'
    $m = Get-Check 'ScalingPlanCoverage'
    Add-CheckResult -Category Cost -CheckName $m.Name -Status Fail -Score 40 `
        -Finding '2 of 5 pooled host pool(s) have a scaling plan assigned. Uncovered: hp-prod-pooled-02, hp-prod-pooled-04, hp-dev-pooled-01.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'StartVmOnConnect'
    Add-CheckResult -Category Cost -CheckName $m.Name -Status Warning -Score 40 `
        -Finding '1 of 2 personal host pool(s) have Start VM on Connect disabled: hp-personal-exec.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'UnhealthyHostsInRotation'
    Add-CheckResult -Category Cost -CheckName $m.Name -Status Pass -Score 100 `
        -Finding 'No unhealthy session hosts are accepting new sessions.' `
        -Remediation '' -LearnMore $m.LearnMore

    $m = Get-Check 'MaxSessionLimit'
    Add-CheckResult -Category Cost -CheckName $m.Name -Status Warning -Score 50 `
        -Finding '1 pooled host pool is at the default session limit (999999): hp-dev-pooled-01.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    Write-Section 'Reliability & Resilience'
    $m = Get-Check 'SessionHostHealth'
    Add-CheckResult -Category Reliability -CheckName $m.Name -Status Fail -Score 80 `
        -Finding '8 of 10 session hosts healthy (80%). Unhealthy: 2 Unavailable.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'RdpShortpath'
    Add-CheckResult -Category Reliability -CheckName $m.Name -Status Warning -Score 50 `
        -Finding '3 of 5 host pool(s) are missing explicit networkautodetect / bandwidthautodetect RDP properties.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'AgentUpdateRing'
    Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
        -Finding '1 host pool(s) in Validation ring, 4 in production ring. Good separation.' `
        -Remediation '' -LearnMore $m.LearnMore

    $m = Get-Check 'SessionCapacityHeadroom'
    Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
        -Finding 'All pooled host pools are below 85% session capacity utilisation.' `
        -Remediation '' -LearnMore $m.LearnMore

    Write-Section 'Security Posture'
    $m = Get-Check 'DriveRedirection'
    Add-CheckResult -Category Security -CheckName $m.Name -Status Warning -Score 40 `
        -Finding '2 host pool(s) allow broad drive redirection (drivestoredirect:s:* or unset): hp-prod-pooled-01, hp-dev-pooled-01.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'ClipboardRedirection'
    Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
        -Finding '4 host pool(s) have clipboard redirection enabled (or at default). This is common but should be a deliberate decision.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'TrustedLaunch'
    Add-CheckResult -Category Security -CheckName $m.Name -Status Warning -Score 60 `
        -Finding '3 of 5 session host VMs are using Trusted Launch. 2 VMs lack Secure Boot / vTPM protection.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'EntraIdJoin'
    Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
        -Finding '3 of 5 session host VM(s) appear to be hybrid-joined or domain-joined only (AADLoginForWindows extension not detected).' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    Write-Section 'Operational Excellence'
    $m = Get-Check 'DiagnosticSettings'
    Add-CheckResult -Category Operations -CheckName $m.Name -Status Fail -Score 40 `
        -Finding '2 of 5 host pool(s) have no diagnostic settings configured: hp-dev-pooled-01, hp-personal-exec, hp-prod-pooled-02.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'ResourceTagging'
    Add-CheckResult -Category Operations -CheckName $m.Name -Status Warning -Score 60 `
        -Finding '2 of 5 host pool(s) are missing Environment or Owner tags: hp-dev-pooled-01, hp-test-01.' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore

    $m = Get-Check 'AgentUpdateState'
    Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
        -Finding 'All session hosts have a healthy agent update state.' `
        -Remediation '' -LearnMore $m.LearnMore

    $m = Get-Check 'LoadBalancingAlgorithm'
    Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
        -Finding '3 pool(s) use BreadthFirst (performance-optimised), 1 pool(s) use DepthFirst (cost-optimised).' `
        -Remediation $m.Remediation -LearnMore $m.LearnMore
}

# ==============================================================================
# AZURE CONNECTION
# ==============================================================================

function Connect-ToAzure {
    Write-Section 'Connecting to Azure'
    if (-not $UseExistingConnection) {
        $connectArgs = @{}
        if ($SubscriptionId) { $connectArgs['Subscription'] = $SubscriptionId }
        if ($TenantId)       { $connectArgs['Tenant']       = $TenantId }
        try {
            Connect-AzAccount @connectArgs -WarningAction SilentlyContinue | Out-Null
        } catch {
            throw "Failed to connect to Azure: $($_.Exception.Message)"
        }
    }

    if ($SubscriptionId) {
        try {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
        } catch {
            throw "Failed to set subscription context to '$SubscriptionId': $($_.Exception.Message)"
        }
    }

    $ctx = Get-AzContext
    if (-not $ctx -or -not $ctx.Subscription) {
        throw 'No active Azure context. Run Connect-AzAccount or omit -UseExistingConnection.'
    }

    $script:Context = [PSCustomObject]@{
        SubscriptionName = $ctx.Subscription.Name
        SubscriptionId   = $ctx.Subscription.Id
        TenantId         = $ctx.Tenant.Id
    }

    Write-Host ('  Subscription : {0} ({1})' -f $ctx.Subscription.Name, $ctx.Subscription.Id) -ForegroundColor Gray
    Write-Host ('  Tenant       : {0}'       -f $ctx.Tenant.Id) -ForegroundColor Gray
}

# ==============================================================================
# DATA COLLECTION
# ==============================================================================

function Get-AvdEnvironmentData {
    Write-Section 'Collecting environment data'

    $script:allHostPools      = @()
    $script:allSessionHosts   = @()
    $script:allScalingPlans   = @()
    $script:allVMs            = @()
    $script:diagnosticSettings = @{}
    $script:hostPoolTags      = @{}
    $script:VmFetchFailed     = $false
    $script:DiagFetchFailed   = $false
    $script:TagFetchFailed    = $false

    # Host pools
    try {
        if ($HostPoolName -and $ResourceGroupName) {
            Write-Host '  Fetching host pool...            ' -NoNewline
            $script:allHostPools = @(Invoke-WithRetry -OperationName 'Get-AzWvdHostPool' -ScriptBlock {
                Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $HostPoolName
            })
        } elseif ($ResourceGroupName) {
            Write-Host '  Fetching host pools...           ' -NoNewline
            $script:allHostPools = @(Invoke-WithRetry -OperationName 'Get-AzWvdHostPool' -ScriptBlock {
                Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName
            })
        } else {
            Write-Host '  Fetching host pools...           ' -NoNewline
            $script:allHostPools = @(Invoke-WithRetry -OperationName 'Get-AzWvdHostPool' -ScriptBlock {
                Get-AzWvdHostPool
            })
        }
        Write-Host ("Found {0} host pool(s)" -f $script:allHostPools.Count) -ForegroundColor Green
    } catch {
        Write-Host 'FAILED' -ForegroundColor Red
        throw "Unable to list host pools: $($_.Exception.Message)"
    }

    $script:HostPoolCount = $script:allHostPools.Count
    if ($script:HostPoolCount -eq 0) {
        Write-Host ''
        Write-Host '  No AVD host pools found in the specified scope. Nothing to assess.' -ForegroundColor Yellow
        return $false
    }

    # Session hosts
    Write-Host '  Fetching session hosts...        ' -NoNewline
    $shList = [System.Collections.Generic.List[object]]::new()
    foreach ($hp in $script:allHostPools) {
        $hpRg   = Get-RgFromArmId -ResourceId $hp.Id
        $hpName = $hp.Name
        try {
            $hosts = @(Invoke-WithRetry -OperationName "Get-AzWvdSessionHost ($hpName)" -ScriptBlock {
                Get-AzWvdSessionHost -ResourceGroupName $hpRg -HostPoolName $hpName -ErrorAction Stop
            })
            foreach ($h in $hosts) {
                $h | Add-Member -NotePropertyName '_HostPoolName'       -NotePropertyValue $hpName      -Force
                $h | Add-Member -NotePropertyName '_HostPoolResourceId' -NotePropertyValue $hp.Id       -Force
                $h | Add-Member -NotePropertyName '_HostPoolType'       -NotePropertyValue $hp.HostPoolType -Force
                $shList.Add($h)
            }
        } catch {
            Write-Verbose "Session host fetch for $hpName failed: $($_.Exception.Message)"
        }
    }
    $script:allSessionHosts   = $shList.ToArray()
    $script:SessionHostCount  = $script:allSessionHosts.Count
    Write-Host ("Found {0} session host(s)" -f $script:SessionHostCount) -ForegroundColor Green

    # Scaling plans
    Write-Host '  Fetching scaling plans...        ' -NoNewline
    try {
        if ($ResourceGroupName) {
            $script:allScalingPlans = @(Invoke-WithRetry -OperationName 'Get-AzWvdScalingPlan' -ScriptBlock {
                Get-AzWvdScalingPlan -ResourceGroupName $ResourceGroupName -ErrorAction Stop
            })
        } else {
            $script:allScalingPlans = @(Invoke-WithRetry -OperationName 'Get-AzWvdScalingPlan' -ScriptBlock {
                Get-AzWvdScalingPlan -ErrorAction Stop
            })
        }
        Write-Host ("Found {0} scaling plan(s)" -f $script:allScalingPlans.Count) -ForegroundColor Green
    } catch {
        $script:allScalingPlans = @()
        Write-Host 'FAILED (continuing)' -ForegroundColor Yellow
    }
    $script:ScalingPlanCount = $script:allScalingPlans.Count

    # VMs
    Write-Host '  Fetching virtual machines...     ' -NoNewline
    $vmList = [System.Collections.Generic.List[object]]::new()
    try {
        $uniqueVmIds = $script:allSessionHosts.ResourceId | Where-Object { $_ } | Select-Object -Unique
        foreach ($vmId in $uniqueVmIds) {
            $parts = $vmId -split '/'
            if ($parts.Count -lt 9) { continue }
            $vmRg   = Get-RgFromArmId -ResourceId $vmId
            $vmName = $parts[-1]
            try {
                $vm = Invoke-WithRetry -OperationName "Get-AzVM ($vmName)" -ScriptBlock {
                    Get-AzVM -ResourceGroupName $vmRg -Name $vmName -Status -ErrorAction Stop
                }
                if ($vm) { $vmList.Add($vm) }
            } catch {
                Write-Verbose "VM fetch failed for $vmId : $($_.Exception.Message)"
            }
        }
        $script:allVMs = $vmList.ToArray()
        Write-Host ("Found {0} AVD virtual machine(s)" -f $script:allVMs.Count) -ForegroundColor Green
    } catch {
        $script:VmFetchFailed = $true
        $script:allVMs = @()
        Write-Host 'FAILED (continuing - VM checks will return Info)' -ForegroundColor Yellow
    }
    if ($script:allSessionHosts.Count -gt 0 -and $script:allVMs.Count -eq 0) {
        $script:VmFetchFailed = $true
    }
    $script:VmCount = $script:allVMs.Count

    # Diagnostic settings
    Write-Host '  Fetching diagnostic settings...  ' -NoNewline
    $diagOk = 0
    foreach ($hp in $script:allHostPools) {
        try {
            $ds = @(Invoke-WithRetry -OperationName "Get-AzDiagnosticSetting ($($hp.Name))" -ScriptBlock {
                Get-AzDiagnosticSetting -ResourceId $hp.Id -ErrorAction Stop
            })
            $script:diagnosticSettings[$hp.Id] = $ds
            $diagOk++
        } catch {
            $script:diagnosticSettings[$hp.Id] = $null
        }
    }
    if ($diagOk -eq 0 -and $script:allHostPools.Count -gt 0) {
        $script:DiagFetchFailed = $true
        Write-Host 'Permission denied (Diagnostic check will return Info)' -ForegroundColor Yellow
    } else {
        Write-Host 'Done' -ForegroundColor Green
    }

    # Tags. Prefer the inline $hp.Tag property when present (saves one ARM call
    # per host pool) and fall back to Get-AzResource only when it's null/missing,
    # since Az.DesktopVirtualization output has historically been inconsistent on
    # whether tags are populated inline.
    Write-Host '  Fetching resource tags...        ' -NoNewline
    $tagOk = 0
    foreach ($hp in $script:allHostPools) {
        $tags = $hp.Tag
        if (-not $tags -or $tags.Count -eq 0) {
            try {
                $res = Invoke-WithRetry -OperationName "Get-AzResource ($($hp.Name))" -ScriptBlock {
                    Get-AzResource -ResourceId $hp.Id -ErrorAction Stop
                }
                $tags = $res.Tags
            } catch {
                $tags = $null
            }
        }
        $script:hostPoolTags[$hp.Id] = $tags
        if ($null -ne $tags) { $tagOk++ }
    }
    if ($tagOk -eq 0 -and $script:allHostPools.Count -gt 0) {
        $script:TagFetchFailed = $true
        Write-Host 'Permission denied (Tag check will return Info)' -ForegroundColor Yellow
    } else {
        Write-Host 'Done' -ForegroundColor Green
    }

    $script:pooledHostPools   = @($script:allHostPools | Where-Object { $_.HostPoolType -eq 'Pooled' })
    $script:personalHostPools = @($script:allHostPools | Where-Object { $_.HostPoolType -eq 'Personal' })

    return $true
}

# ==============================================================================
# CHECKS: COST OPTIMISATION
# ==============================================================================

function Invoke-CostChecks {
    Write-Section 'Cost Optimisation'

    # Check 1: Scaling Plan Coverage
    $m = Get-Check 'ScalingPlanCoverage'
    if ($script:pooledHostPools.Count -eq 0) {
        Add-CheckResult -Category Cost -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No pooled host pools found. Scaling plans apply to pooled host pools only.' `
            -Remediation 'No action required.' `
            -LearnMore $m.LearnMore
    } else {
        $referencedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sp in $script:allScalingPlans) {
            foreach ($ref in @($sp.HostPoolReference)) {
                if ($ref -and $ref.HostPoolArmPath) {
                    [void]$referencedIds.Add($ref.HostPoolArmPath)
                }
            }
        }
        $covered   = @($script:pooledHostPools | Where-Object { $referencedIds.Contains($_.Id) })
        $uncovered = @($script:pooledHostPools | Where-Object { -not $referencedIds.Contains($_.Id) })
        if ($uncovered.Count -eq 0) {
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} pooled host pool(s) have a scaling plan configured." -f $script:pooledHostPools.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $pct = [int][math]::Round(($covered.Count / $script:pooledHostPools.Count) * 100)
            $names = ($uncovered | ForEach-Object { $_.Name }) -join ', '
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Fail -Score $pct `
                -Finding ("{0} of {1} pooled host pool(s) have a scaling plan. Uncovered: {2}." -f $covered.Count, $script:pooledHostPools.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 2: Start VM on Connect (Personal)
    $m = Get-Check 'StartVmOnConnect'
    if ($script:personalHostPools.Count -eq 0) {
        Add-CheckResult -Category Cost -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No personal host pools found. Start VM on Connect applies to personal host pools.' `
            -Remediation 'No action required.' -LearnMore $m.LearnMore
    } else {
        $offPools = @($script:personalHostPools | Where-Object { -not $_.StartVMOnConnect })
        if ($offPools.Count -eq 0) {
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} personal host pool(s) have Start VM on Connect enabled." -f $script:personalHostPools.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $names = ($offPools | ForEach-Object { $_.Name }) -join ', '
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Warning -Score 40 `
                -Finding ("{0} of {1} personal host pool(s) have Start VM on Connect disabled: {2}." -f $offPools.Count, $script:personalHostPools.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 3: Unhealthy hosts still in rotation
    $m = Get-Check 'UnhealthyHostsInRotation'
    $unhealthyStates = @('Unavailable','NeedsAssistance','UpgradeFailed','NoHeartbeat')
    $stillRotating = @($script:allSessionHosts | Where-Object {
        ($unhealthyStates -contains $_.Status) -and ($_.AllowNewSession -eq $true)
    })
    if ($stillRotating.Count -eq 0) {
        Add-CheckResult -Category Cost -CheckName $m.Name -Status Pass -Score 100 `
            -Finding 'No unhealthy session hosts are accepting new sessions.' `
            -Remediation '' -LearnMore $m.LearnMore
    } else {
        $names = ($stillRotating | ForEach-Object { ($_.Name -split '/')[-1] }) -join ', '
        Add-CheckResult -Category Cost -CheckName $m.Name -Status Warning -Score 30 `
            -Finding ("{0} unhealthy host(s) still accepting new sessions: {1}." -f $stillRotating.Count, $names) `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    }

    # Check 4: Max Session Limit
    $m = Get-Check 'MaxSessionLimit'
    if ($script:pooledHostPools.Count -eq 0) {
        Add-CheckResult -Category Cost -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No pooled host pools found. Max session limit applies to pooled host pools.' `
            -Remediation 'No action required.' -LearnMore $m.LearnMore
    } else {
        $bad = @($script:pooledHostPools | Where-Object { $_.MaxSessionLimit -ge 999999 -or $_.MaxSessionLimit -le 0 })
        if ($bad.Count -eq 0) {
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} pooled host pool(s) have a realistic max session limit." -f $script:pooledHostPools.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $names = ($bad | ForEach-Object { $_.Name }) -join ', '
            Add-CheckResult -Category Cost -CheckName $m.Name -Status Warning -Score 50 `
                -Finding ("{0} pooled host pool(s) at the default or invalid session limit: {1}." -f $bad.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }
}

# ==============================================================================
# CHECKS: RELIABILITY & RESILIENCE
# ==============================================================================

function Invoke-ReliabilityChecks {
    Write-Section 'Reliability & Resilience'

    # Check 5: Session host health
    $m = Get-Check 'SessionHostHealth'
    if ($script:allSessionHosts.Count -eq 0) {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No session hosts found across the assessed host pools.' `
            -Remediation 'Deploy session hosts into your host pool(s) to begin serving users.' `
            -LearnMore $m.LearnMore
    } else {
        $healthyStates = @('Available','Shutdown')
        $unhealthy = @($script:allSessionHosts | Where-Object { $healthyStates -notcontains $_.Status })
        if ($unhealthy.Count -eq 0) {
            Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} session host(s) are healthy." -f $script:allSessionHosts.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $healthyCount = $script:allSessionHosts.Count - $unhealthy.Count
            $pct = [int][math]::Round(($healthyCount / $script:allSessionHosts.Count) * 100)
            $breakdown = ($unhealthy | Group-Object Status | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
            Add-CheckResult -Category Reliability -CheckName $m.Name -Status Fail -Score $pct `
                -Finding ("{0} of {1} session host(s) healthy ({2}%). Unhealthy: {3}." -f $healthyCount, $script:allSessionHosts.Count, $pct, $breakdown) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 6: RDP Shortpath / network auto-detect
    $m = Get-Check 'RdpShortpath'
    $missing = @($script:allHostPools | Where-Object {
        $nad = Get-RdpProperty -RdpString $_.CustomRdpProperty -PropertyName 'networkautodetect'
        $bad = Get-RdpProperty -RdpString $_.CustomRdpProperty -PropertyName 'bandwidthautodetect'
        ($nad -ne '1') -or ($bad -ne '1')
    })
    if ($missing.Count -eq 0) {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
            -Finding ("All {0} host pool(s) have network auto-detect properties set for RDP Shortpath." -f $script:allHostPools.Count) `
            -Remediation '' -LearnMore $m.LearnMore
    } else {
        $names = ($missing | ForEach-Object { $_.Name }) -join ', '
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Warning -Score 50 `
            -Finding ("{0} of {1} host pool(s) missing explicit networkautodetect / bandwidthautodetect: {2}." -f $missing.Count, $script:allHostPools.Count, $names) `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    }

    # Check 7: Agent update ring
    $m = Get-Check 'AgentUpdateRing'
    $validationCount = @($script:allHostPools | Where-Object { $_.ValidationEnvironment -eq $true }).Count
    $total = $script:allHostPools.Count
    if ($validationCount -gt 0 -and $validationCount -lt $total) {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
            -Finding ("{0} host pool(s) are in the Validation ring, {1} in production ring. Good separation." -f $validationCount, ($total - $validationCount)) `
            -Remediation '' -LearnMore $m.LearnMore
    } elseif ($validationCount -eq 0) {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Warning -Score 70 `
            -Finding 'No host pools are on the validation ring. No early warning for AVD agent updates.' `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    } else {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Warning -Score 40 `
            -Finding 'All host pools are on the Validation ring. Production users are receiving pre-release agent updates.' `
            -Remediation $m.RemediationAllValidation -LearnMore $m.LearnMore
    }

    # Check 8: Session capacity headroom
    $m = Get-Check 'SessionCapacityHeadroom'
    if ($script:pooledHostPools.Count -eq 0) {
        Add-CheckResult -Category Reliability -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No pooled host pools found. Capacity check applies to pooled host pools.' `
            -Remediation 'No action required.' -LearnMore $m.LearnMore
    } else {
        $overCapacity = [System.Collections.Generic.List[object]]::new()
        foreach ($hp in $script:pooledHostPools) {
            $hostsInPool = @($script:allSessionHosts | Where-Object { $_._HostPoolResourceId -eq $hp.Id })
            if ($hostsInPool.Count -eq 0) { continue }
            if ($hp.MaxSessionLimit -le 0 -or $hp.MaxSessionLimit -ge 999999) { continue }
            $total = ($hostsInPool | Measure-Object -Property Session -Sum).Sum
            if (-not $total) { $total = ($hostsInPool | Measure-Object -Property Sessions -Sum).Sum }
            if (-not $total) { $total = 0 }
            $capacity = $hp.MaxSessionLimit * $hostsInPool.Count
            if ($capacity -le 0) { continue }
            $util = $total / $capacity
            if ($util -gt 0.85) {
                $overCapacity.Add([PSCustomObject]@{ Name = $hp.Name; Pct = [int][math]::Round($util * 100) })
            }
        }
        if ($overCapacity.Count -eq 0) {
            Add-CheckResult -Category Reliability -CheckName $m.Name -Status Pass -Score 100 `
                -Finding 'All pooled host pools are below 85% session capacity utilisation.' `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $detail = ($overCapacity | ForEach-Object { "$($_.Name) ($($_.Pct)%)" }) -join ', '
            Add-CheckResult -Category Reliability -CheckName $m.Name -Status Warning -Score 30 `
                -Finding ("{0} pool(s) over 85% capacity: {1}." -f $overCapacity.Count, $detail) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }
}

# ==============================================================================
# CHECKS: SECURITY POSTURE
# ==============================================================================

function Invoke-SecurityChecks {
    Write-Section 'Security Posture'

    # Check 9: Drive redirection
    $m = Get-Check 'DriveRedirection'
    $risky = @($script:allHostPools | Where-Object {
        $v = Get-RdpProperty -RdpString $_.CustomRdpProperty -PropertyName 'drivestoredirect'
        ($null -eq $v) -or ($v -eq '*')
    })
    if ($risky.Count -eq 0) {
        Add-CheckResult -Category Security -CheckName $m.Name -Status Pass -Score 100 `
            -Finding ("All {0} host pool(s) have drive redirection explicitly restricted." -f $script:allHostPools.Count) `
            -Remediation '' -LearnMore $m.LearnMore
    } else {
        $names = ($risky | ForEach-Object { $_.Name }) -join ', '
        Add-CheckResult -Category Security -CheckName $m.Name -Status Warning -Score 40 `
            -Finding ("{0} host pool(s) allow broad drive redirection (drivestoredirect:s:* or unset): {1}." -f $risky.Count, $names) `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    }

    # Check 10: Clipboard redirection (always Info)
    $m = Get-Check 'ClipboardRedirection'
    $clip = @($script:allHostPools | Where-Object {
        $v = Get-RdpProperty -RdpString $_.CustomRdpProperty -PropertyName 'redirectclipboard'
        ($null -eq $v) -or ($v -eq '1')
    })
    if ($clip.Count -eq 0) {
        Add-CheckResult -Category Security -CheckName $m.Name -Status Pass -Score 100 `
            -Finding ("All {0} host pool(s) have clipboard redirection explicitly disabled." -f $script:allHostPools.Count) `
            -Remediation '' -LearnMore $m.LearnMore
    } else {
        Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
            -Finding ("{0} host pool(s) have clipboard redirection enabled (or at default). This is common but should be a deliberate decision." -f $clip.Count) `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    }

    # Check 11: Trusted Launch
    $m = Get-Check 'TrustedLaunch'
    if ($script:VmFetchFailed -or $script:allVMs.Count -eq 0) {
        Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'Unable to retrieve VM data - Reader permissions may be missing on the compute resources. Skipping Trusted Launch check.' `
            -Remediation 'Grant the Reader role on the VM resource groups (or subscription) so AVD-Assess can read VM properties, then re-run.' `
            -LearnMore $m.LearnMore
    } else {
        $trusted = @($script:allVMs | Where-Object { $_.SecurityProfile -and $_.SecurityProfile.SecurityType -eq 'TrustedLaunch' })
        if ($trusted.Count -eq $script:allVMs.Count) {
            Add-CheckResult -Category Security -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} session host VM(s) are using Trusted Launch." -f $script:allVMs.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $pct = [int][math]::Round(($trusted.Count / $script:allVMs.Count) * 100)
            Add-CheckResult -Category Security -CheckName $m.Name -Status Warning -Score $pct `
                -Finding ("{0} of {1} session host VM(s) using Trusted Launch ({2}%). Others lack Secure Boot / vTPM protection." -f $trusted.Count, $script:allVMs.Count, $pct) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 12: Entra ID join (Info only)
    $m = Get-Check 'EntraIdJoin'
    if ($script:VmFetchFailed -or $script:allVMs.Count -eq 0) {
        Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'Unable to retrieve VM data - join status could not be evaluated.' `
            -Remediation 'Grant Reader access to the VM resource groups so AVD-Assess can inspect VM extensions.' `
            -LearnMore $m.LearnMore
    } else {
        $entra = @($script:allVMs | Where-Object {
            $exts = @($_.Extensions)
            ($exts | Where-Object { $_.Name -eq 'AADLoginForWindows' -or $_.VirtualMachineExtensionType -eq 'AADLoginForWindows' }).Count -gt 0
        })
        $other = $script:allVMs.Count - $entra.Count
        if ($other -eq 0) {
            Add-CheckResult -Category Security -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} session host VM(s) appear to be Entra ID joined." -f $script:allVMs.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            Add-CheckResult -Category Security -CheckName $m.Name -Status Info -Score 100 `
                -Finding ("{0} of {1} session host VM(s) appear to be hybrid-joined or domain-joined only (AADLoginForWindows extension not detected). Entra ID join is the recommended approach for new AVD deployments." -f $other, $script:allVMs.Count) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }
}

# ==============================================================================
# CHECKS: OPERATIONAL EXCELLENCE
# ==============================================================================

function Invoke-OperationsChecks {
    Write-Section 'Operational Excellence'

    # Check 13: Diagnostic settings
    $m = Get-Check 'DiagnosticSettings'
    if ($script:DiagFetchFailed) {
        Add-CheckResult -Category Operations -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'Unable to read diagnostic settings - permissions to Microsoft.Insights may be missing.' `
            -Remediation 'Grant Monitoring Reader on the host pool resource group(s) and re-run.' `
            -LearnMore $m.LearnMore
    } else {
        $noDiag = @($script:allHostPools | Where-Object {
            $ds = $script:diagnosticSettings[$_.Id]
            (-not $ds) -or ($ds.Count -eq 0) -or -not ($ds | Where-Object { $_.WorkspaceId })
        })
        if ($noDiag.Count -eq 0) {
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} host pool(s) have diagnostic settings sending logs to Log Analytics." -f $script:allHostPools.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $ok = $script:allHostPools.Count - $noDiag.Count
            $pct = [int][math]::Round(($ok / $script:allHostPools.Count) * 100)
            $names = ($noDiag | ForEach-Object { $_.Name }) -join ', '
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Fail -Score $pct `
                -Finding ("{0} of {1} host pool(s) missing diagnostic settings: {2}." -f $noDiag.Count, $script:allHostPools.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 14: Resource tagging
    $m = Get-Check 'ResourceTagging'
    if ($script:TagFetchFailed) {
        Add-CheckResult -Category Operations -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'Unable to read resource tags - permissions may be missing.' `
            -Remediation 'Grant Reader on the subscription or host pool resource groups and re-run.' `
            -LearnMore $m.LearnMore
    } else {
        $missingTags = @($script:allHostPools | Where-Object {
            $tags = $script:hostPoolTags[$_.Id]
            $hasEnv   = $tags -and ($tags.Keys | Where-Object { $_ -ieq 'Environment' })
            $hasOwner = $tags -and ($tags.Keys | Where-Object { $_ -ieq 'Owner' })
            -not ($hasEnv -and $hasOwner)
        })
        if ($missingTags.Count -eq 0) {
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
                -Finding ("All {0} host pool(s) have Environment and Owner tags." -f $script:allHostPools.Count) `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $ok = $script:allHostPools.Count - $missingTags.Count
            $pct = [int][math]::Round(($ok / $script:allHostPools.Count) * 100)
            $names = ($missingTags | ForEach-Object { $_.Name }) -join ', '
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Warning -Score $pct `
                -Finding ("{0} of {1} host pool(s) missing Environment or Owner tag: {2}." -f $missingTags.Count, $script:allHostPools.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 15: Agent update state
    $m = Get-Check 'AgentUpdateState'
    if ($script:allSessionHosts.Count -eq 0) {
        Add-CheckResult -Category Operations -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No session hosts found.' `
            -Remediation 'No action required.' -LearnMore $m.LearnMore
    } else {
        $badUpdate = @($script:allSessionHosts | Where-Object { $_.UpdateState -in @('Failed','Stalled') })
        if ($badUpdate.Count -eq 0) {
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
                -Finding 'All session hosts have a healthy agent update state.' `
                -Remediation '' -LearnMore $m.LearnMore
        } else {
            $ok = $script:allSessionHosts.Count - $badUpdate.Count
            $pct = [int][math]::Round(($ok / $script:allSessionHosts.Count) * 100)
            $names = ($badUpdate | ForEach-Object { ($_.Name -split '/')[-1] + " ($($_.UpdateState))" }) -join ', '
            Add-CheckResult -Category Operations -CheckName $m.Name -Status Fail -Score $pct `
                -Finding ("{0} session host(s) have a Failed or Stalled agent update: {1}." -f $badUpdate.Count, $names) `
                -Remediation $m.Remediation -LearnMore $m.LearnMore
        }
    }

    # Check 16: Load balancing algorithm (always Pass / informational)
    $m = Get-Check 'LoadBalancingAlgorithm'
    if ($script:pooledHostPools.Count -eq 0) {
        Add-CheckResult -Category Operations -CheckName $m.Name -Status Info -Score 100 `
            -Finding 'No pooled host pools found. Load balancing algorithm applies to pooled host pools only.' `
            -Remediation 'No action required.' -LearnMore $m.LearnMore
    } else {
        $bf = @($script:pooledHostPools | Where-Object { $_.LoadBalancerType -eq 'BreadthFirst' }).Count
        $df = @($script:pooledHostPools | Where-Object { $_.LoadBalancerType -eq 'DepthFirst' }).Count
        Add-CheckResult -Category Operations -CheckName $m.Name -Status Pass -Score 100 `
            -Finding ("Load balancing review: {0} pool(s) use BreadthFirst (performance-optimised - spreads users across more VMs), {1} pool(s) use DepthFirst (cost-optimised - fills VMs before starting new ones)." -f $bf, $df) `
            -Remediation $m.Remediation -LearnMore $m.LearnMore
    }
}

# ==============================================================================
# SCORING
# ==============================================================================

function Get-CategoryScore {
    param([string]$Category)
    $items = @($script:Checks | Where-Object { $_.Category -eq $Category -and $_.Status -ne 'Info' })
    if ($items.Count -eq 0) { return 100 }
    $avg = ($items | Measure-Object -Property Score -Average).Average
    return [int][math]::Round($avg)
}

function Get-OverallScore {
    $cats = @('Cost','Reliability','Security','Operations')
    $scores = $cats | ForEach-Object { Get-CategoryScore $_ }
    return [int][math]::Round(($scores | Measure-Object -Average).Average)
}

# ==============================================================================
# HTML REPORT
# ==============================================================================

function New-CategoryCardHtml {
    param([string]$Category, [string]$DisplayName)
    $score  = Get-CategoryScore -Category $Category
    $donut  = New-DonutSvg -Score $score -Size 96
    $checks = @($script:Checks | Where-Object { $_.Category -eq $Category })

    $rows = [System.Text.StringBuilder]::new()
    foreach ($c in $checks) {
        $cls    = Get-StatusClass -Status $c.Status
        $label  = Get-StatusSymbol -Status $c.Status
        $name   = ConvertTo-HtmlSafe $c.CheckName
        $find   = ConvertTo-HtmlSafe $c.Finding
        $rem    = ConvertTo-HtmlSafe $c.Remediation
        $learn  = ''
        if ($c.LearnMore) {
            $urlSafe = ConvertTo-HtmlSafe $c.LearnMore
            $learn   = "<a class=""learn"" href=""$urlSafe"" target=""_blank"" rel=""noopener"">Microsoft Learn &rarr;</a>"
        }
        $remBlock = ''
        if ($c.Remediation) {
            $remBlock = @"
      <div class="remediation">
        <div class="rem-label">Remediation</div>
        <div>$rem</div>
        $learn
      </div>
"@
        } elseif ($learn) {
            $remBlock = "<div class=""remediation-link"">$learn</div>"
        }
        [void]$rows.AppendLine(@"
  <div class="check-row" onclick="this.classList.toggle('expanded')">
    <div class="check-head">
      <span class="check-name">$name</span>
      <span class="status $cls">$label</span>
    </div>
    <div class="check-detail">
      <div class="finding">$find</div>
$remBlock
    </div>
  </div>
"@)
    }

    return @"
<section class="category-card">
  <div class="category-head">
    $donut
    <div class="category-meta">
      <div class="sub">$DisplayName</div>
      <div class="cat-score">$score<span class="cat-score-suffix">/100</span></div>
    </div>
  </div>
  <div class="check-list">
$($rows.ToString())
  </div>
</section>
"@
}

function New-HtmlReport {
    $overall = Get-OverallScore
    $overallDonut = New-DonutSvg -Score $overall -Size 140
    $generated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')

    $subName = ConvertTo-HtmlSafe $script:Context.SubscriptionName
    $subId   = ConvertTo-HtmlSafe $script:Context.SubscriptionId
    $tenant  = ConvertTo-HtmlSafe $script:Context.TenantId

    $cardCost   = New-CategoryCardHtml -Category 'Cost'        -DisplayName 'Cost Optimisation'
    $cardRel    = New-CategoryCardHtml -Category 'Reliability' -DisplayName 'Reliability & Resilience'
    $cardSec    = New-CategoryCardHtml -Category 'Security'    -DisplayName 'Security Posture'
    $cardOps    = New-CategoryCardHtml -Category 'Operations'  -DisplayName 'Operational Excellence'

    $css = @'
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: #0a1f2e;
  color: #ffffff;
  line-height: 1.5;
  min-height: 100vh;
  -webkit-font-smoothing: antialiased;
}
.container { max-width: 1200px; margin: 0 auto; padding: 32px 24px 48px; }
header.hero {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 24px;
  background: #0D2535;
  border: 1px solid #1a3547;
  border-radius: 16px;
  padding: 32px;
  margin-bottom: 20px;
}
.brand {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.brand-name {
  font-size: 36px;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: #ffffff;
}
.brand-name .dot { color: #B3FF00; }
.brand-sub {
  font-size: 13px;
  color: #94a3b8;
  letter-spacing: 0.02em;
}
.overall {
  display: flex;
  align-items: center;
  gap: 20px;
}
.overall .label {
  font-size: 11px;
  color: #94a3b8;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: 4px;
}
.overall .big {
  font-size: 54px;
  font-weight: 800;
  color: #ffffff;
  line-height: 1;
  letter-spacing: -0.02em;
}
.overall .suffix {
  font-size: 20px;
  font-weight: 600;
  color: #64748b;
  margin-left: 4px;
}
.meta-bar {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
  gap: 1px;
  background: #1a3547;
  border: 1px solid #1a3547;
  border-radius: 12px;
  overflow: hidden;
  margin-bottom: 28px;
}
.meta-bar .cell { background: #0D2535; padding: 14px 18px; }
.meta-bar .meta-label {
  font-size: 10px;
  color: #94a3b8;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: 5px;
  font-weight: 600;
}
.meta-bar .meta-value {
  font-size: 14px;
  color: #ffffff;
  font-weight: 500;
  word-break: break-all;
}
.categories {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(480px, 1fr));
  gap: 20px;
}
.category-card {
  background: #0D2535;
  border: 1px solid #1a3547;
  border-radius: 16px;
  padding: 28px;
}
.category-head {
  display: flex;
  align-items: center;
  gap: 20px;
  margin-bottom: 20px;
  padding-bottom: 20px;
  border-bottom: 1px solid #1a3547;
}
.category-meta .sub {
  font-size: 11px;
  color: #94a3b8;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  font-weight: 600;
  margin-bottom: 4px;
}
.category-meta .cat-score {
  font-size: 34px;
  font-weight: 800;
  color: #ffffff;
  line-height: 1;
  letter-spacing: -0.02em;
}
.category-meta .cat-score-suffix {
  font-size: 14px;
  color: #64748b;
  font-weight: 600;
  margin-left: 3px;
}
.check-list { display: flex; flex-direction: column; gap: 4px; }
.check-row {
  cursor: pointer;
  border-radius: 8px;
  transition: background 140ms ease;
  user-select: none;
}
.check-row:hover { background: rgba(255,255,255,0.03); }
.check-row.expanded { background: rgba(255,255,255,0.04); }
.check-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 12px 14px;
}
.check-name { font-size: 14px; color: #ffffff; font-weight: 500; }
.status {
  display: inline-flex;
  align-items: center;
  padding: 3px 10px;
  border-radius: 12px;
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  white-space: nowrap;
  flex-shrink: 0;
}
.status.pass { color: #22c55e; background: rgba(34,197,94,0.12);  border: 1px solid rgba(34,197,94,0.35); }
.status.warn { color: #f59e0b; background: rgba(245,158,11,0.12); border: 1px solid rgba(245,158,11,0.35); }
.status.fail { color: #ef4444; background: rgba(239,68,68,0.12);  border: 1px solid rgba(239,68,68,0.35); }
.status.info { color: #33CCCC; background: rgba(51,204,204,0.12); border: 1px solid rgba(51,204,204,0.35); }
.check-detail {
  display: none;
  padding: 4px 14px 14px 14px;
  font-size: 13px;
  color: #cbd5e1;
}
.check-row.expanded .check-detail { display: block; }
.check-detail .finding { margin-bottom: 12px; line-height: 1.6; }
.check-detail .remediation {
  background: rgba(51,204,204,0.06);
  border-left: 3px solid #33CCCC;
  padding: 12px 14px;
  border-radius: 4px;
  color: #e2e8f0;
  line-height: 1.6;
}
.check-detail .rem-label {
  font-size: 11px;
  color: #33CCCC;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: 6px;
}
.learn {
  display: inline-block;
  margin-top: 10px;
  color: #33CCCC;
  text-decoration: none;
  font-weight: 500;
  font-size: 13px;
  border-bottom: 1px dashed rgba(51,204,204,0.5);
  padding-bottom: 1px;
}
.learn:hover { color: #B3FF00; border-bottom-color: #B3FF00; }
.remediation-link { margin-top: 8px; }
.donut { flex-shrink: 0; }
footer {
  margin-top: 32px;
  padding-top: 24px;
  border-top: 1px solid #1a3547;
  color: #64748b;
  font-size: 13px;
  text-align: center;
}
footer a { color: #33CCCC; text-decoration: none; }
footer a:hover { color: #B3FF00; }
@media (max-width: 760px) {
  header.hero { flex-direction: column; align-items: flex-start; }
  .overall { align-self: flex-end; }
  .categories { grid-template-columns: 1fr; }
}
'@

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AVD-Assess Report &mdash; $subName</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">
<style>$css</style>
</head>
<body>
<div class="container">
  <header class="hero">
    <div class="brand">
      <div class="brand-name">AVD<span class="dot">-</span>Assess</div>
      <div class="brand-sub">Azure Virtual Desktop Health Report</div>
    </div>
    <div class="overall">
      $overallDonut
      <div>
        <div class="label">Overall Score</div>
        <div class="big">$overall<span class="suffix">/100</span></div>
      </div>
    </div>
  </header>

  <div class="meta-bar">
    <div class="cell"><div class="meta-label">Subscription</div><div class="meta-value">$subName</div></div>
    <div class="cell"><div class="meta-label">Subscription ID</div><div class="meta-value">$subId</div></div>
    <div class="cell"><div class="meta-label">Tenant</div><div class="meta-value">$tenant</div></div>
    <div class="cell"><div class="meta-label">Host Pools</div><div class="meta-value">$($script:HostPoolCount)</div></div>
    <div class="cell"><div class="meta-label">Session Hosts</div><div class="meta-value">$($script:SessionHostCount)</div></div>
    <div class="cell"><div class="meta-label">Generated</div><div class="meta-value">$generated</div></div>
  </div>

  <div class="categories">
    $cardCost
    $cardRel
    $cardSec
    $cardOps
  </div>

  <footer>
    AVD-Assess v$script:ToolVersion &middot;
    <a href="$script:WebsiteUrl" target="_blank" rel="noopener">modern-euc.com</a> &middot;
    <a href="$script:ProjectUrl" target="_blank" rel="noopener">github.com/waynebellows/AVD-Assess</a>
  </footer>
</div>
</body>
</html>
"@
    return $html
}

# ==============================================================================
# MAIN
# ==============================================================================

function Invoke-Main {
    Write-Banner

    if ($DryRun) {
        Initialize-DryRunData
    } else {
        Assert-RequiredModules
        Connect-ToAzure
        $hasData = Get-AvdEnvironmentData
        if (-not $hasData) {
            Write-Host ''
            Write-Host '  Nothing to report. Exiting.' -ForegroundColor Yellow
            return
        }
        Invoke-CostChecks
        Invoke-ReliabilityChecks
        Invoke-SecurityChecks
        Invoke-OperationsChecks
    }

    # Score summary
    $cost = Get-CategoryScore 'Cost'
    $rel  = Get-CategoryScore 'Reliability'
    $sec  = Get-CategoryScore 'Security'
    $ops  = Get-CategoryScore 'Operations'
    $overall = Get-OverallScore

    Write-Section 'Score Summary'
    Write-Host ("  Cost Optimisation      : {0}/100" -f $cost)    -ForegroundColor White
    Write-Host ("  Reliability            : {0}/100" -f $rel)     -ForegroundColor White
    Write-Host ("  Security Posture       : {0}/100" -f $sec)     -ForegroundColor White
    Write-Host ("  Operational Excellence : {0}/100" -f $ops)     -ForegroundColor White
    Write-Host ''
    Write-Host ("  Overall Score          : {0}/100" -f $overall) -ForegroundColor Cyan

    # Render HTML
    $html = New-HtmlReport

    if (-not $OutputPath) {
        $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath "AVD-Assess-Report-$stamp.html"
    }
    $outDir = Split-Path -Parent $OutputPath
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))

    Write-Host ''
    Write-Host ("  Report saved to: {0}" -f $OutputPath) -ForegroundColor Green
    Write-Host ''

    if ($OpenReport) {
        try { Start-Process -FilePath $OutputPath | Out-Null }
        catch { Write-Host "  (Could not open report automatically: $($_.Exception.Message))" -ForegroundColor Yellow }
    }
}

Invoke-Main
