# AVD-Assess v2.0 — Roadmap & Design Draft

**Status:** Draft  
**Author:** Wayne Bellows  
**Target release:** TBD

---

## Why v2

v1 covers **four** of the five Microsoft Well-Architected Framework pillars for Azure Virtual Desktop. The fifth — **Performance Efficiency** — is missing entirely. v2 closes that gap and extends the four existing categories with the highest-leverage checks identified in the [WAF for AVD documentation](https://learn.microsoft.com/en-us/azure/well-architected/azure-virtual-desktop/).

v2 also turns AVD-Assess from a **snapshot** into a **trend** by adding JSON output and compare-to-previous mode, and supports multi-subscription estates — the common shape of real enterprise AVD deployments.

---

## Headline numbers

| | v1.0 | v2.0 |
|---|---|---|
| WAF pillars covered | 4/5 | **5/5** |
| Total checks | 16 | **24** |
| Output formats | HTML | **HTML, JSON, Both** |
| Subscription scope | Single | **Single or sweep** |
| Trend tracking | — | **Compare-to-previous** |

---

## New category: Performance Efficiency (4 checks)

The 5th WAF pillar. New donut on the report; check rows live alongside Cost / Reliability / Security / Operations.

### PE1 — Accelerated Networking

**Detection.** For each session host VM, resolve its primary NIC via `$vm.NetworkProfile.NetworkInterfaces[0].Id`, then `Get-AzNetworkInterface -ResourceId $nicId` and read `.EnableAcceleratedNetworking`.

**Scoring.** Pass if 100% of session host NICs have it enabled. Proportional Warning otherwise (% enabled = score). Info if VM SKU doesn't support it (rare on modern SKUs).

**Why it matters.** Free perf win — typically halves end-to-end latency on supported SKUs and is silently off on a huge proportion of estates because it's not enabled by default in older deployment templates. Single highest-ROI Performance check.

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview

---

### PE2 — Premium SSD for production OS disks

**Detection.** For each session host VM, read `$vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType`. Values: `Premium_LRS`, `PremiumV2_LRS`, `UltraSSD_LRS`, `StandardSSD_LRS`, `Standard_LRS`.

**Scoring.**
- Pass — all session hosts on Premium / PremiumV2 / Ultra
- Warning — any **multi-session** session host on Standard_LRS or StandardSSD_LRS (proportional)
- Info — personal pools on Standard SSD (WAF guidance is softer here: *"Use standard or premium SSDs for personal desktops"*)

**Why it matters.** WAF: *"Use premium SSDs for Windows 10 or Windows 11 Enterprise Multi-Session."* Sub-premium OS disks on multi-session hosts are the #1 cause of "users complain about slow logon" tickets after FSLogix region mismatch.

**Learn More:** https://learn.microsoft.com/en-us/azure/well-architected/azure-virtual-desktop/storage#vm-and-disk-sizing

---

### PE3 — VM generation (Gen2)

**Detection.** Read `$vm.StorageProfile.OsDisk.ManagedDisk.Id` → `Get-AzDisk -ResourceId <id>` → `.HyperVGeneration`. Returns `V1` or `V2`.

**Scoring.** Pass if all Gen2. Warning if any Gen1 (proportional).

**Why it matters.** Gen1 blocks Trusted Launch (already a v1 Security check), Confidential VMs, large memory configurations, and several Windows 11 features. New deployments default to Gen2 since 2022 — Gen1 in 2026 means the image lineage is stale.

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2

---

### PE4 — FSLogix storage region colocation

**Detection.** Hard problem — there's no ARM API to ask *"which storage account does this host pool's FSLogix use?"*. Two-stage discovery:

1. Look for a tag convention on the host pool (default: `FSLogixStorageAccount`, configurable via new `-FSLogixTagName` parameter).
2. Fall back to a name-pattern scan of storage accounts in the host pool's resource group (default pattern: `*fslogix*`, configurable via `-FSLogixNamePattern`).

For each discovered (host pool, storage account) pair, compare `$storageAccount.Location` to host pool `.Location`.

**Scoring.**
- Pass — all FSLogix storage colocated with their host pool
- Warning — any cross-region pairing (named with the latency penalty estimate)
- Info — couldn't identify FSLogix storage for any host pool (suggest tag convention)

**Why it matters.** Cross-region FSLogix profile traffic adds 40–80 ms to every `OpenFile` against the profile container, which means *every application launch* and *every Outlook search* in the user's session. Single biggest "why is sign-in slow" cause and currently invisible to v1.

**Learn More:** https://learn.microsoft.com/en-us/azure/well-architected/azure-virtual-desktop/storage#region-selection

---

## Existing categories — new checks (4 additions)

### Reliability

#### R5 — Availability Zone distribution

**Detection.** For each pooled host pool with ≥2 session hosts, count distinct values of `$vm.Zones[0]` across the pool's VMs.

**Scoring.** Pass if hosts spread across ≥2 zones. Warning if all hosts in a single zone (or `$vm.Zones` empty). Info if region doesn't support AZs.

**Why it matters.** WAF: *"Deploy your session hosts in an availability zone."* Single-AZ pools take a full outage when an AZ has a problem. Pairs naturally with the existing Session Host Health check.

**Learn More:** https://learn.microsoft.com/en-us/azure/reliability/availability-zones-overview

---

#### R6 — FSLogix profile redundancy

**Detection.** Same FSLogix discovery as PE4. For each storage account found, read `$sa.Sku.Name` (`Standard_LRS` / `Standard_ZRS` / `Standard_GRS` / `Standard_GZRS` / `Standard_RAGRS` / `Premium_LRS` / `Premium_ZRS`).

**Scoring.** Pass if ZRS, GZRS, RA-GZRS, or Premium_ZRS. Warning if LRS / GRS (no zone redundancy). Info if FSLogix storage couldn't be identified.

**Why it matters.** WAF: *"Use zone-redundant storage to replicate data synchronously across Azure availability zones."* LRS profile shares + multi-AZ session host pools = users locked out of their profiles in a single-AZ outage even though the compute is fine.

**Learn More:** https://learn.microsoft.com/en-us/azure/storage/common/storage-redundancy

---

### Security

#### S5 — Defender for Cloud coverage

**Detection.** `Get-AzSecurityPricing` and inspect entries for `VirtualMachines` and `StorageAccounts` resource types.

**Scoring.** Pass if `PricingTier` ≠ `Free` for VirtualMachines (and ideally StorageAccounts too). Warning otherwise.

**Why it matters.** WAF: *"Turn on Microsoft Defender for Cloud for cloud security posture management."* Defender for Servers gives you vulnerability assessment, file integrity monitoring, and adaptive application controls — none of which fire in Free tier.

**Learn More:** https://learn.microsoft.com/en-us/azure/defender-for-cloud/

---

#### S6 — AVD Private Link / public network access

**Detection.** Read `$hp.PublicNetworkAccess` (Az.DesktopVirtualization ≥ 4.0 exposes this). For host pools where it's `Enabled`, check whether a private endpoint exists by querying `Get-AzPrivateEndpoint -ResourceGroupName <rg>` and matching by `PrivateLinkServiceConnections[0].PrivateLinkServiceId`.

**Scoring.** Pass if `PublicNetworkAccess = Disabled` or a private endpoint exists. Warning if `Enabled` without a private endpoint.

**Why it matters.** WAF: *"Implement Private Link to securely connect to remote Azure Virtual Desktop and related services privately."* Public-internet-exposed AVD control plane is unnecessary for any enterprise deployment with site-to-site connectivity.

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/private-link-overview

---

### Operations

#### O5 — Service Health alerts

**Detection.** `Get-AzActivityLogAlert` and filter for `ServiceHealth` category alerts that include the `Microsoft.DesktopVirtualization` resource provider in their condition.

**Scoring.** Pass if at least one Service Health alert covers AVD in the assessed scope. Warning if none.

**Why it matters.** WAF: *"Set up Service Health alerts so that you stay aware of service issues, planned maintenance, or other changes that might affect your Azure Virtual Desktop resources."* Most AVD outages are knowable in advance via Service Health — alerts turn that knowledge into a notification.

**Learn More:** https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-service-alerts

---

## Tooling: output formats and trends

### T1 — JSON output

**New parameter:** `-OutputFormat HTML|JSON|Both` (default: `HTML`)

When `JSON` or `Both`, write `<basename>.json` alongside the HTML report. Schema:

```json
{
  "tool": "AVD-Assess",
  "version": "2.0.0",
  "generatedAt": "2026-04-27T14:23:00Z",
  "environment": {
    "subscriptionId": "...",
    "subscriptionName": "...",
    "tenantId": "...",
    "hostPoolCount": 5,
    "sessionHostCount": 47,
    "scalingPlanCount": 3,
    "vmCount": 47
  },
  "scores": {
    "overall": 66,
    "categories": {
      "Cost": 58,
      "Reliability": 82,
      "Security": 50,
      "Operations": 75,
      "Performance": 60
    }
  },
  "checks": [
    {
      "id": "ScalingPlanCoverage",
      "category": "Cost",
      "name": "Scaling Plan Coverage",
      "status": "Fail",
      "score": 40,
      "finding": "...",
      "remediation": "...",
      "learnMore": "https://...",
      "affectedResources": ["hp-prod-pooled-02", "..."]
    }
  ]
}
```

**Foundation for everything that follows** — compare mode, dashboards, CI/CD gates.

---

### T2 — Compare to previous

**New parameter:** `-CompareTo <path-to-previous-json>`

When set:

- HTML report shows `▲ +5` / `▼ −3` / `=` next to each score (overall, per-category, per-check)
- JSON output (if also enabled) gains `delta` keys at every score level
- New checks added since the previous run are marked `(new)`
- Removed checks are noted in a separate "no longer assessed" section

Crucial for the question every sponsor actually asks: *"is this getting better or worse?"*

---

### T3 — Multi-subscription sweep

**New parameter:** `-AllAccessibleSubscriptions`

When set:

- Iterate `Get-AzSubscription` for all subscriptions accessible to the current context
- Produce one HTML/JSON pair per subscription, named `AVD-Assess-Report-<subscription-shortname>-<timestamp>.html`
- Produce a roll-up `index.html` listing all subscriptions with their overall scores and direct links into each detailed report
- Subscriptions with no AVD resources are skipped silently

Most enterprise AVD estates span 2–5 subs (separate prod/dev/dr) — single-sub mode is the wrong default for that audience.

---

## Refactor prerequisites (must land first)

These have no user-facing effect but are needed before the new checks can be implemented cleanly.

### Refactor 1 — Check catalog

Extract every check's `Name`, `Remediation`, and `LearnMore` into a single `$script:CheckCatalog` hashtable keyed by check ID. Both the real check functions and the dry-run seeder read from it. Eliminates the duplication problem v1 has, where `Initialize-DryRunData` and the per-check functions both inline the same remediation strings.

### Refactor 2 — Wider data collection

Add to `Get-AvdEnvironmentData`:

- `Get-AzNetworkInterface` for each session host VM's primary NIC (PE1)
- `Get-AzDisk` for each session host VM's OS disk (PE2, PE3)
- `Get-AzStorageAccount` for FSLogix-tagged or pattern-matched storage accounts (PE4, R6)
- `Get-AzSecurityPricing` (S5)
- `Get-AzPrivateEndpoint` per resource group (S6)
- `Get-AzActivityLogAlert` (O5)

Each fetch wrapped in `Invoke-WithRetry` (already in v1.1) and degrades affected checks to `Info` on permission failure (existing pattern).

### Refactor 3 — HTML grid for 5 categories

Current 2×2 layout becomes either 5 cards in a 3+2 flow (CSS grid `repeat(auto-fit, minmax(...))` already handles this — just need to verify visual balance) or a top-row Performance card spanning full width with the existing 2×2 below.

---

## Out of scope for v2.0

Deliberately deferred — listed so they're not forgotten:

| Feature | Why deferred |
|---|---|
| Conditional Access policy checks | Requires `Microsoft.Graph` PowerShell module — adds significant install footprint for one finding. Viable as v2.1 with `-IncludeIdentityChecks` opt-in. |
| AppLocker / Defender Antivirus on session hosts | Requires in-VM inspection (registry / WMI) — out of scope per original single-file PowerShell design. |
| `ForEach-Object -Parallel` data collection | Premature optimisation. Sequential collection is fine to ~200 host pools. Revisit when real-world reports show sub-3-minute runs becoming a complaint. |
| CI/CD gate mode (`-FailOnScoreBelow N`) | Easy add but no clear demand yet — wait for first user request. |
| Azure Lighthouse multi-tenant | Niche; adds auth complexity. Most users have one tenant. |
| Image vintage / age check | Defer to v2.1 — needs a curated catalogue of image SKUs and their EOL dates. |
| Trusted Signing of the script | Defer until first user reports SmartScreen friction. |

---

## Implementation order

1. **Refactor 1 (check catalog)** — touches every existing check call site; do it first while the diff is small.
2. **Refactor 2 (wider data collection)** — additive, no behaviour change to v1 checks.
3. **Refactor 3 (HTML grid)** — small CSS change; verify 5-card layout in dry-run.
4. **PE1 (Accelerated Networking)** — simplest new check, validates the new data-collection scaffolding.
5. **PE2, PE3 (OS disk type, Gen2)** — same data shape as PE1.
6. **PE4 + R6 (FSLogix discovery + redundancy)** — paired because they share the discovery logic.
7. **R5 (AZ distribution)** — uses VM data already in scope.
8. **S5, S6 (Defender, Private Link)** — new data sources.
9. **O5 (Service Health alerts)** — new data source.
10. **T1 (JSON output)** — schema lock, then implementation.
11. **T2 (compare-to-previous)** — depends on T1.
12. **T3 (multi-sub sweep)** — last, because it iterates everything above.
13. **Docs + screenshots** — README update, new screenshot showing 5 categories, CONTRIBUTING update for the new check workflow.

Each step is its own PR, mergeable independently, with parse-check + dry-run verification per step.

---

## Migration impact for existing users

- All v1 parameters remain valid and behave identically
- New parameters are additive; defaults preserve v1 behaviour
- HTML report grows from 4 → 5 category cards; existing screenshots in customer reports remain accurate for content but will look different
- Required Az modules unchanged from v1 (no new dependencies for the v2.0 scope above)

---

## Open questions

1. **FSLogix discovery default tag name.** `FSLogixStorageAccount` proposed — is there an industry convention, or should we stay configurable with no default?
2. **5-card HTML layout.** 3+2 flow vs. full-width Performance card on top vs. let CSS auto-fit decide?
3. **JSON schema versioning.** Add `schemaVersion: "1.0"` to the JSON envelope so future breaking changes can be detected by consumers.
4. **`-AllAccessibleSubscriptions` permission story.** Reader on each sub is required — should we pre-flight check and skip subs where the current identity has no rights, or fail loudly?

These should be resolved (issue or PR discussion) before the first v2.0 PR lands.
