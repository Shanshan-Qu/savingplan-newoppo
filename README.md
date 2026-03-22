# Azure Compute Savings Plan Opportunity Analyzer

A PowerShell script that analyses your Azure Pay-As-You-Go (PAYG) compute spend, accounts for any **existing** Savings Plans already in place, and models where additional Savings Plan commitments could further reduce your bill — at both **Subscription** and **Management Group** scope.

> **Read-only** — the script never purchases anything or makes changes to your Azure environment.

---

## Contents

- [What is an Azure Compute Savings Plan?](#what-is-an-azure-compute-savings-plan)
- [How the Script Works](#how-the-script-works)
- [Understanding the Gap Calculation](#understanding-the-gap-calculation)
- [Prerequisites](#prerequisites)
- [Required Permissions](#required-permissions)
- [Parameters](#parameters)
- [Usage Examples](#usage-examples)
- [Reading the Output](#reading-the-output)
- [Important Notes](#important-notes)
- [Troubleshooting](#troubleshooting)
- [Next Steps After Running](#next-steps-after-running)

---

## What is an Azure Compute Savings Plan?

An Azure Compute Savings Plan is a commitment to spend a fixed **hourly dollar amount** on eligible compute services over 1 or 3 years, in exchange for a discount off the Pay-As-You-Go rate.

| Term   | Approx. discount vs PAYG |
|--------|--------------------------|
| 1-Year | ~37%                     |
| 3-Year | ~52%                     |

**Eligible services:**

- Azure Virtual Machines (all sizes and regions)
- Azure Dedicated Host
- Azure Kubernetes Service (compute portion)
- Azure Container Instances
- Azure App Service (Premium v3 plans)
- Azure Functions (Premium / Elastic Premium plans)

> **Savings Plans vs Reservations:** A Savings Plan commitment applies automatically across regions and VM sizes. Reservations lock to a specific VM SKU and region but may offer a slightly higher discount for that exact SKU. Both can coexist.

---

## How the Script Works

```
┌─────────────────────────────────────────────────────────────┐
│  1. AUTHENTICATE                                            │
│     Uses your existing Az PowerShell session, or prompts   │
│     for interactive login.                                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  2. DETECT SCOPE                                            │
│     Determines if the scope is a Subscription or           │
│     Management Group and adjusts API calls accordingly.     │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  3. FETCH EXISTING SAVINGS PLANS                            │
│     Calls the BillingBenefits API to enumerate all active  │
│     SP orders. Filters to plans that apply to your scope   │
│     (Shared / MG-scoped / Subscription-scoped).            │
│     Sums the total existing hourly commitment.              │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  4. FETCH COST DATA (last N days)                           │
│     Calls Cost Management API for all compute spend,       │
│     broken down by pricing model:                           │
│       OnDemand    = PAYG (full undiscounted price)          │
│       SavingsPlan = already SP-covered (discounted rate)    │
│       Reservation = already RI-covered (discounted rate)    │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  5. CALCULATE HOURLY BASELINE                               │
│     Derives P30 / P50 / P70 percentiles from daily PAYG    │
│     spend history and converts them to hourly rates.        │
│                                                             │
│     P30 = spend level exceeded 70% of days (Conservative)  │
│     P50 = median daily spend          (Moderate)            │
│     P70 = spend level exceeded 30% of days (Aggressive)    │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  6. CALCULATE THE GAP                                       │
│     Gap = Baseline Hourly − Existing SP Hourly Commitment   │
│     Only the gap is modelled for additional SP purchases.   │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  7. MODEL ADDITIONAL SAVINGS                                │
│     For each gap scenario calculates:                       │
│       • Additional hourly commitment required               │
│       • New annual commitment cost                          │
│       • Estimated annual saving (1-Year and 3-Year)         │
│       • Payback period in months                            │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│  8. PRINT REPORT  +  OPTIONAL CSV EXPORT                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Understanding the Gap Calculation

```
  Your PAYG Hourly Baseline  (P30 / P50 / P70)
            −
  Your Existing SP Hourly Commitment  (auto-detected)
            =
  GAP  ←  this is the additional hourly amount to consider committing
```

**Example:**

| Item | Rate |
|------|------|
| P50 PAYG baseline (median daily spend ÷ 24) | $25.00/hr |
| Existing active Savings Plans | $10.00/hr |
| **Remaining GAP** | **$15.00/hr** |
| New 1-Year SP annual commitment (gap × 8,760 hrs) | $131,400/yr |
| Estimated additional saving at ~37% | **$48,618/yr** |

If the gap is **zero or negative**, your existing Savings Plans already cover the selected baseline — no additional purchase is needed at that commitment level.

---

## Prerequisites

### PowerShell Module

Install once on the machine running the script:

```powershell
Install-Module Az.Accounts -Scope CurrentUser -Force
```

---

## Required Permissions

Two Azure RBAC roles are required:

| Role | Assign at | Purpose |
|------|-----------|---------|
| **Cost Management Reader** | Target Subscription **or** Management Group | Read cost and billing data |
| **Billing Reader** | Billing Account (tenant root) | Auto-detect existing Savings Plan orders |

> **If Billing Reader cannot be granted:** Use `-ManualExistingSpHourlyAUD` to provide the existing commitment total manually. The cost analysis section still runs in full.

### Assign via Azure Portal

1. Go to **Subscriptions** or **Management Groups** in the Azure Portal
2. Select the target scope → **Access control (IAM)** → **Add role assignment**
3. Search for `Cost Management Reader` and assign it to the user or service principal

For Billing Reader: **Cost Management + Billing** → select your **Billing Account** → **Access control (IAM)** → **Add role assignment**

### Assign via PowerShell

```powershell
# Cost Management Reader on a Subscription
New-AzRoleAssignment -ObjectId "<object-id>" `
    -RoleDefinitionName "Cost Management Reader" `
    -Scope "/subscriptions/<subscription-id>"

# Cost Management Reader on a Management Group
New-AzRoleAssignment -ObjectId "<object-id>" `
    -RoleDefinitionName "Cost Management Reader" `
    -Scope "/providers/Microsoft.Management/managementGroups/<mg-id>"
```

---

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-BillingScope` | **Yes** | — | ARM scope string (see format below) |
| `-LookbackDays` | No | `30` | Days of cost history to analyse (7–365) |
| `-ManualExistingSpHourlyAUD` | No | auto-detect | Total existing SP hourly commitment if BillingBenefits API is inaccessible |
| `-OutputCsvPath` | No | — | File path prefix for CSV exports (three files created) |

### Scope Format

```
# Single Subscription
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Management Group (covers all child subscriptions)
/providers/Microsoft.Management/managementGroups/<management-group-id>
```

Find your **Subscription ID**: Azure Portal → Subscriptions  
Find your **Management Group ID**: Azure Portal → Management Groups

---

## Usage Examples

### Single subscription — 30-day lookback (default)

```powershell
.\Analyze-SavingsPlanOpportunity.ps1 `
    -BillingScope "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Management Group — all child subscriptions combined

```powershell
.\Analyze-SavingsPlanOpportunity.ps1 `
    -BillingScope "/providers/Microsoft.Management/managementGroups/<mg-id>" `
    -LookbackDays 60
```

### Export results to CSV files

```powershell
.\Analyze-SavingsPlanOpportunity.ps1 `
    -BillingScope "/providers/Microsoft.Management/managementGroups/<mg-id>" `
    -LookbackDays 30 `
    -OutputCsvPath "C:\Reports\SP_Analysis"
```

Three CSV files are created:

| File | Contents |
|------|----------|
| `SP_Analysis_PAYG_Detail.csv` | Raw PAYG compute rows from Cost Management |
| `SP_Analysis_Gap_Model.csv` | Savings model table (all three scenarios) |
| `SP_Analysis_ExistingSPs.csv` | List of existing active Savings Plan orders |

### Billing Reader not available — manual commitment override

```powershell
# Find existing SP hourly commitment:
# Azure Portal → Cost Management → Savings Plans → open each plan → view commitment amount

.\Analyze-SavingsPlanOpportunity.ps1 `
    -BillingScope "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ManualExistingSpHourlyAUD 12.50
```

### Longer lookback to capture seasonal patterns

```powershell
.\Analyze-SavingsPlanOpportunity.ps1 `
    -BillingScope "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -LookbackDays 90
```

A 90-day lookback smooths out seasonal spikes and gives a more stable P30/P50/P70 baseline.

---

## Reading the Output

### Existing Savings Plan Orders

```
  Plan Name                            Term   Hourly     Scope Type    Applied Scope
  ──────────────────────────────────────────────────────────────────────────────────
  Prod-SP-2025                         P1Y    AUD  8.50  Shared
  Dev-SP-2025                          P1Y    AUD  3.20  Subscription  /subscriptions/...
```

- `P1Y` = 1-Year term, `P3Y` = 3-Year term
- `Shared` = applies across all subscriptions in the billing account
- `ManagementGroup` = applies to all subscriptions in that MG
- `Subscription` = applies to that one subscription only

### Executive Summary

```
  Total Compute (PAYG + SP + RI)   : AUD 45,230.00
  ├─ PAYG (OnDemand) — uncovered   : AUD 28,000.00  (61.9%)
  ├─ Savings Plan covered          : AUD 12,500.00  (27.6%)  [discounted rate]
  └─ Reservation covered           : AUD  4,730.00  (10.5%)  [discounted rate]

  P30 Hourly (Conservative)        : AUD 32.10/hr
  P50 Hourly (Moderate)            : AUD 38.50/hr
  P70 Hourly (Aggressive)          : AUD 44.20/hr

  Existing SP Hourly Commitment    : AUD 11.70/hr  (2 active plans)
  Coverage of P50 Baseline         : [█████████████░░░░░░░░░░░░] 30.4%
```

### Gap Model

```
  Scenario               Gap /hr     New Annual Commit   PAYG Coverage   1-Yr Saving   3-Yr Saving
  Conservative – P30     AUD 20.40   AUD 178,704         52.9%           AUD 66,120    AUD 92,926
  Moderate   – P50       AUD 26.80   AUD 234,648         69.6%           AUD 86,820    AUD 122,017
  Aggressive – P70       AUD 32.50   AUD 284,700         84.4%           AUD 105,339   AUD 148,044
```

### Choosing a scenario

| Workload pattern | Recommended scenario |
|-----------------|----------------------|
| Always-on, very stable (production 24/7) | **Aggressive – P70** |
| Mostly stable with some variability | **Moderate – P50** |
| Variable, includes dev/test or batch workloads | **Conservative – P30** |
| New environment / unknown pattern | Start **Conservative**, review in 3 months |

---

## Important Notes

1. **Discount rates are indicative.** The script uses ~37% (1-Year) and ~52% (3-Year) as typical Compute Savings Plan rates. Actual rates vary by region, currency, VM family and any Enterprise Agreement discounts. Always validate in the Azure Portal purchase simulator before committing.

2. **PAYG rows reflect full list price.** The script uses `ActualCost` data from Cost Management. `OnDemand` rows are at the full undiscounted rate; `SavingsPlan` rows are at the already-discounted rate. This is intentional — the gap is measured in terms of spend that would cost full price if left uncovered.

3. **Savings Plans and Reservations coexist.** Existing Reservations (RI) are tracked separately and shown in the summary. A Savings Plan covers spend not already matched by a Reservation. For fixed VM SKUs in a fixed region running 24/7, Reservations typically offer a slightly higher discount than a Savings Plan for that specific SKU.

4. **Management Group queries may take 30–60 seconds.** The Cost Management API processes large MG-scoped queries asynchronously. The script handles the 202-retry pattern automatically.

5. **Cost data has a 1–2 day lag.** Azure Cost Management reflects usage 24–48 hours after it occurs. The script automatically offsets the end date to yesterday to avoid missing data.

6. **This script is entirely read-only.** No resources are modified and no purchases are made. To purchase a Savings Plan, go to: **Azure Portal → Cost Management → Savings Plans → Purchase**.

---

## Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|-------------|-----------|
| `Cost Management API call failed` | Missing `Cost Management Reader` role | Assign the role at the subscription or MG scope |
| `Could not retrieve existing Savings Plans` | Missing `Billing Reader` at billing account scope | Assign Billing Reader, or use `-ManualExistingSpHourlyAUD` |
| No PAYG rows found | All compute is already covered by SPs/RIs | Review existing coverage — this may mean full commitment is already in place |
| Very low gap percentage | SP coverage is already high | Consider whether to extend term or wait for existing SPs to expire before renewing |
| MG query times out | Very large number of child subscriptions | Increase PowerShell timeout, or run per-subscription using Subscription scope |

---

## Next Steps After Running

1. **Validate in the Azure Portal purchase simulator**  
   Cost Management → Savings Plans → Purchase → enter the recommended hourly commitment → review Microsoft's projected savings and break-even point.

2. **Check Azure Advisor recommendations**  
   Portal → Advisor → Cost → look for "Purchase a savings plan" alerts. Microsoft's ML-based recommendation uses 30 days of telemetry from your actual usage.

3. **Review expiry dates on existing SPs**  
   Plans that expire revert to PAYG pricing. Set a reminder 60 days before expiry to review and renew.

4. **Consider Reservations for stable single-SKU workloads**  
   If specific VM sizes run 24/7 in a fixed region, a Reservation may offer an additional 5–10% discount on top of or instead of a Savings Plan for that SKU.

5. **Re-run this analysis quarterly**  
   Workloads change. Re-running every 3 months ensures your commitment level stays aligned with actual usage.

---

## Files in This Repository

| File | Description |
|------|-------------|
| `Analyze-SavingsPlanOpportunity.ps1` | Main PowerShell analysis script |
| `SavingsPlan_Analysis.kql` | KQL queries for Azure Data Explorer / Log Analytics (Cost Management export) |
| `README.md` | This guide |

---

## License

MIT License — see [LICENSE](LICENSE) for details.
