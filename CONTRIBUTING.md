# Contributing to AVD-Assess

Thanks for your interest in improving AVD-Assess. This is a single-file PowerShell tool by design — contributions should preserve that simplicity.

## Adding a new check

Every check lives inside `AVD-Assess.ps1` and registers its outcome by calling `Add-CheckResult`. The data model is:

```powershell
Add-CheckResult `
    -Category    'Cost' `                # Cost | Reliability | Security | Operations
    -CheckName   'Scaling Plan Coverage' `
    -Status      'Pass' `                # Pass | Warning | Fail | Info
    -Score       100 `                   # 0-100
    -Finding     'What was found, with specific counts / names.' `
    -Remediation 'What to do about it, with concrete steps.' `
    -LearnMore   'https://learn.microsoft.com/...'
```

Rules of thumb for new checks:

- **Be specific in findings.** Name the affected host pool / VM / session host. Counts and percentages beat adjectives.
- **Be actionable in remediation.** A reader should be able to fix the problem without a second search. Quote the exact property, cmdlet, or portal blade.
- **Link to Microsoft Learn**, not a blog. If no Learn article exists, link the closest official Azure doc.
- **Score proportionally** where possible (e.g. % of hosts compliant). Reserve Fail < 40 for material risk.
- **Use `Info` sparingly** — it's for checks that don't apply to the environment (e.g. no personal host pools) or are educational-only (e.g. load-balancing algorithm review). `Info` checks are excluded from category averages.
- **Read from the pre-collected script-scoped data** (`$script:allHostPools`, `$script:allSessionHosts`, etc.) rather than making fresh Azure calls inside the check.

## Testing a change

1. **Parse-check the script locally:**
   ```powershell
   [System.Management.Automation.Language.Parser]::ParseFile(
       "$PWD\AVD-Assess.ps1", [ref]$null, [ref]$null
   ) | Out-Null
   ```
2. **Render the HTML offline** using the hidden dry-run switch:
   ```powershell
   ./AVD-Assess.ps1 -DryRun -OutputPath ./_dryrun.html -OpenReport
   ```
   This seeds synthetic results for all 16 checks and produces a full report without hitting Azure. Useful for verifying UI changes and new categories/statuses.
3. **Run against a real subscription** with a varied configuration (mix of pooled / personal, scaling plans present / absent, healthy / unhealthy hosts). Ideally a dev subscription — this tool is read-only but you should still scope carefully.

## Pull request guidelines

- **One check or one self-contained improvement per PR.** Easier to review, easier to revert.
- **Include test evidence** — a screenshot of the new report section, or the relevant console output.
- **Explain the Pass / Warning / Fail thresholds** in the PR description, especially for any proportional scoring.
- **Match the existing style** — 4-space indentation, `Verb-Noun` function names, comment-based help on functions, banner comments separating major sections.
- **No new module dependencies** beyond the five Az modules already required.
- **Keep the single-file structure.** Do not split into modules, dot-sourced files, or sub-folders.

## Reporting issues

Open an issue on GitHub with:

- PowerShell version (`$PSVersionTable.PSVersion`)
- Az module versions (`Get-Module Az.* -ListAvailable | Select Name, Version`)
- The full console output (redact any subscription or tenant IDs)
- Whether the problem is reproducible against a different subscription

## Licence

By contributing you agree that your work is licensed under the MIT licence of this project.
