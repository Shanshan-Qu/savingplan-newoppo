<#
.SYNOPSIS
    Analyses existing Savings Plan coverage and identifies the remaining PAYG
    compute gap where additional Savings Plans could be applied.

.DESCRIPTION
    This script:
      1. Detects whether the scope is a Management Group or Subscription.
      2. Queries Azure Cost Management for PAYG, Savings Plan, and Reservation
         compute spend over the lookback period.
      3. Calls the BillingBenefits API to enumerate ALL active Savings Plan
         orders and their current hourly commitment amounts, filtered to those
         that apply to the given scope.
      4. Calls the Capacity API to enumerate ALL active Reservations (RIs),
         filtered to those that apply to the given scope, with expiry warnings.
      5. Calculates the GAP = (remaining PAYG baseline hourly rate) minus
         (existing active SP hourly commitment already applied to this scope).
      6. Models additional SP purchase options based only on this gap.
      7. Reports RI coverage breakdown by meter category and resource group,
         and warns on RIs expiring within 90 / 180 days.

    Azure Compute Savings Plan covers: VMs, Azure Dedicated Hosts, Container
    Instances, AKS (compute portion), App Service Premium v3, Azure Functions
    Premium (EP) plans.

    Approximate discount rates vs PAYG:
        1-Year Compute Savings Plan : ~37%
        3-Year Compute Savings Plan : ~52%
        1-Year VM Reservation       : ~40%  (varies by SKU and region)
        3-Year VM Reservation       : ~60%  (varies by SKU and region)

.PREREQUISITES
    Install-Module Az.Accounts -Scope CurrentUser -Force

.PERMISSIONS
    Three Azure RBAC roles are required:

        Role 1 : Cost Management Reader
        Scope  : The subscription or management group passed as -BillingScope
        Why    : Reads cost/billing data via the Cost Management Query API.

        Role 2 : Billing Reader  (or any role with
                 Microsoft.BillingBenefits/savingsPlanOrders/read)
        Scope  : Tenant root / Billing Account
        Why    : Reads existing Savings Plan orders from the BillingBenefits API.
                 Without this the script still runs but existing SP commitments
                 cannot be auto-detected (manual override available).

        Role 3 : Reservations Reader  (or Owner/Contributor on the reservations,
                 or Reader at the Enrollment/Billing Account scope)
        Scope  : Tenant root  (/providers/Microsoft.Capacity/reservationOrders)
        Why    : Reads existing Reservation (RI) orders from the Capacity API.
                 Without this the script still runs but RI inventory and expiry
                 dates will not be shown (Cost Management data still provides
                 RI spend figures).

    Assign via Portal:
        Subscriptions / Management Groups → IAM → Add role assignment
        Billing Account → IAM → Billing Reader
        Azure Portal → Reservations → Select reservation → IAM → Reservations Reader

    Assign via PowerShell (Cost Management Reader example):
        New-AzRoleAssignment -ObjectId <ObjectId> `
            -RoleDefinitionName "Cost Management Reader" `
            -Scope "/subscriptions/<subscription-id>"

.BILLING DATA NOTES
    Uses type = "ActualCost" from Cost Management. Row meanings:
      • PricingModel = "OnDemand"     → PAYG, FULL undiscounted rate
      • PricingModel = "SavingsPlan"  → already SP-covered, discounted rate
      • PricingModel = "Reservation"  → already RI-covered, discounted rate

    PAYG rows are used as the gap analysis base. SP-covered rows are converted
    to their PAYG-equivalent cost (by dividing by (1 - discount rate)) so that
    the total eligible compute baseline is accurate before netting off the
    existing SP commitment.

.SCOPE BEHAVIOUR
    Subscription scope  "/subscriptions/<id>"
        → Costs and SP coverage queried for that subscription only.
        → Existing SPs filtered to those scoped to this subscription or "Shared".

    Management Group scope  "/providers/Microsoft.Management/managementGroups/<id>"
        → Costs rolled up across all child subscriptions.
        → Existing SPs filtered to those scoped to this MG or "Shared".
        → Per-subscription cost breakdown included in the report.

.PARAMETER BillingScope
    ARM scope string. Examples:
        Subscription    : "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        ManagementGroup : "/providers/Microsoft.Management/managementGroups/<mg-id>"

.PARAMETER LookbackDays
    Days of cost history to analyse. Range 7–365. Default: 30.

.PARAMETER ManualExistingSpHourlyAUD
    Optional. If the BillingBenefits API is unavailable (insufficient permissions),
    supply the total existing active SP hourly commitment in AUD here.
    Run: Get-AzBillingBenefitsSavingsPlanOrder | to find existing commitments.

.PARAMETER OutputCsvPath
    Optional path prefix for CSV exports.

.EXAMPLE
    # Subscription scope
    .\Analyze-SavingsPlanOpportunity.ps1 `
        -BillingScope "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -LookbackDays 30

.EXAMPLE
    # Management Group scope
    .\Analyze-SavingsPlanOpportunity.ps1 `
        -BillingScope "/providers/Microsoft.Management/managementGroups/ZE-Root" `
        -LookbackDays 30 `
        -OutputCsvPath "C:\Reports\ZE_SP_Gap"

.EXAMPLE
    # Manual SP commitment override (if BillingBenefits API access is unavailable)
    .\Analyze-SavingsPlanOpportunity.ps1 `
        -BillingScope "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ManualExistingSpHourlyAUD 12.50
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $BillingScope,

    [Parameter(Mandatory = $false)]
    [ValidateRange(7, 365)]
    [int] $LookbackDays = 30,

    [Parameter(Mandatory = $false)]
    [double] $ManualExistingSpHourlyAUD = -1,   # -1 = auto-detect via API

    [Parameter(Mandatory = $false)]
    [string] $OutputCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ──────────────────────────────────────────────────────────
$SP_DISCOUNT_1YR = 0.37   # ~37% saving vs PAYG for 1-Year Compute SP
$SP_DISCOUNT_3YR = 0.52   # ~52% saving vs PAYG for 3-Year Compute SP
$RI_DISCOUNT_1YR = 0.40   # ~40% saving vs PAYG for 1-Year VM Reservation (indicative; varies by SKU/region)
$RI_DISCOUNT_3YR = 0.60   # ~60% saving vs PAYG for 3-Year VM Reservation (indicative; varies by SKU/region)

$COMPUTE_METER_CATEGORIES = @(
    'Virtual Machines',
    'Azure Dedicated Host',
    'Container Instances',
    'Azure Kubernetes Service',
    'Azure App Service',
    'Azure Functions'
)
#endregion

#region ── Helpers ────────────────────────────────────────────────────────────
function Write-Section ([string]$Title) {
    Write-Host "`n$('─' * 75)" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$('─' * 75)" -ForegroundColor Cyan
}

function Format-Currency ([double]$Amount, [string]$Symbol = 'AUD') {
    return "$Symbol {0:N2}" -f $Amount
}

function Get-PercentageBar ([double]$Percent, [int]$Width = 25) {
    $filled = [math]::Min([math]::Round($Percent / 100 * $Width), $Width)
    $bar    = ('█' * $filled) + ('░' * ($Width - $filled))
    return "[$bar] {0:N1}%" -f $Percent
}

function Invoke-CostManagementQuery ([string]$Scope, [string]$Token, [hashtable]$Body) {
    $uri     = "https://management.azure.com$Scope/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $headers = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $json    = $Body | ConvertTo-Json -Depth 10

    # Cost Management may return 202 + retry for large scopes (MG with many subscriptions)
    $maxRetries = 5
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Method POST -Uri $uri -Headers $headers -Body $json -UseBasicParsing
            if ($resp.StatusCode -eq 200) {
                return ($resp.Content | ConvertFrom-Json)
            }
            if ($resp.StatusCode -eq 202) {
                $retryAfter = [int]($resp.Headers['Retry-After'] ?? 5)
                Write-Host "    MG query queued (202). Polling in $retryAfter s... (attempt $attempt/$maxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $retryAfter
                # Poll the Location URL
                $pollUri = $resp.Headers['Location']
                if ($pollUri) {
                    $pollResp = Invoke-WebRequest -Method GET -Uri $pollUri -Headers $headers -UseBasicParsing
                    if ($pollResp.StatusCode -eq 200) { return ($pollResp.Content | ConvertFrom-Json) }
                }
            }
        } catch {
            throw "Cost Management API error: $($_.Exception.Message)"
        }
    }
    throw "Cost Management query did not complete after $maxRetries attempts."
}
#endregion

#region ── Scope Detection ────────────────────────────────────────────────────
$scopeType = if ($BillingScope -match '^/providers/Microsoft\.Management/managementGroups/(.+)$') {
    'ManagementGroup'
} elseif ($BillingScope -match '^/subscriptions/([0-9a-f-]{36})$') {
    'Subscription'
} else {
    Write-Error "Unsupported scope format: $BillingScope`nUse '/subscriptions/<id>' or '/providers/Microsoft.Management/managementGroups/<id>'"
    exit 1
}
$scopeId = if ($scopeType -eq 'ManagementGroup') { $Matches[1] } else { $Matches[1] }
#endregion

#region ── Authentication ─────────────────────────────────────────────────────
Write-Section "Authentication"
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Host "  No active session found. Launching interactive login..." -ForegroundColor Yellow
        Connect-AzAccount | Out-Null
        $context = Get-AzContext
    }
    Write-Host "  Signed in as  : $($context.Account.Id)" -ForegroundColor Green
    Write-Host "  Tenant        : $($context.Tenant.Id)"
    Write-Host "  Scope type    : $scopeType  ($scopeId)"
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
} catch {
    Write-Error "Authentication failed: $_"
    exit 1
}
#endregion

#region ── Date Range ─────────────────────────────────────────────────────────
$endDate   = (Get-Date).Date
$startDate = $endDate.AddDays(-$LookbackDays)
$dateFrom  = $startDate.ToString('yyyy-MM-dd')
$dateTo    = $endDate.AddDays(-1).ToString('yyyy-MM-dd')

Write-Section "Query Parameters"
Write-Host "  Scope         : $BillingScope"
Write-Host "  Period        : $dateFrom  →  $dateTo  ($LookbackDays days)"
#endregion

#region ── Fetch Existing Savings Plans (BillingBenefits API) ─────────────────
Write-Section "Fetching Existing Savings Plan Orders"

$existingSPs        = @()
$existingSpHourly   = 0.0
$spFetchWarning     = $false

if ($ManualExistingSpHourlyAUD -ge 0) {
    $existingSpHourly = $ManualExistingSpHourlyAUD
    Write-Host "  Using manually supplied existing SP hourly commitment: $(Format-Currency $existingSpHourly)/hr" -ForegroundColor Yellow
} else {
    try {
        $spApiUri = "https://management.azure.com/providers/Microsoft.BillingBenefits/savingsPlanOrders?api-version=2022-11-01&`$expand=savingsPlanOrders/savingsPlans"
        $spHeaders = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
        $spResp   = Invoke-RestMethod -Method GET -Uri $spApiUri -Headers $spHeaders

        $allPlans = @()
        $page = $spResp
        while ($page) {
            foreach ($order in $page.value) {
                foreach ($plan in $order.savingsPlans) {
                    $allPlans += [PSCustomObject]@{
                        OrderId          = $order.name
                        PlanId           = $plan.name
                        DisplayName      = $plan.properties.displayName
                        Status           = $plan.properties.status
                        Term             = $plan.properties.term             # P1Y / P3Y
                        AppliedScopeType = $plan.properties.appliedScopeType # Shared / Subscription / ManagementGroup
                        AppliedScopes    = $plan.properties.appliedScopes    # array of scope IDs
                        HourlyCommitment = [double]($plan.properties.commitment.amount)
                        Currency         = $plan.properties.commitment.currencyCode
                        ExpiryDate       = $plan.properties.expiryDateTime
                    }
                }
            }
            $page = if ($page.nextLink) { Invoke-RestMethod -Method GET -Uri $page.nextLink -Headers $spHeaders } else { $null }
        }

        $activePlans = $allPlans | Where-Object { $_.Status -eq 'Active' }

        # Filter to plans that cover this scope:
        #   "Shared"         → covers everything in the billing account (always include)
        #   "ManagementGroup"→ include if the applied MG ID matches our scopeId
        #   "Subscription"   → include if the applied sub ID matches our scopeId
        #                       OR if our scope is an MG (plan covers a child sub → partial coverage)
        $relevantPlans = $activePlans | Where-Object {
            $scope = $_
            switch ($scope.AppliedScopeType) {
                'Shared'          { $true }
                'ManagementGroup' {
                    # Matches if any applied scope ends with our MG ID
                    $scope.AppliedScopes | Where-Object { $_ -match [regex]::Escape($scopeId) }
                }
                'Subscription'    {
                    if ($scopeType -eq 'Subscription') {
                        # Matches if the applied sub ID matches our subscription
                        $scope.AppliedScopes | Where-Object { $_ -match [regex]::Escape($scopeId) }
                    } else {
                        # MG scope: include subscription-level plans as partial coverage (shown but not summed)
                        $false   # excluded from hourly total; shown separately
                    }
                }
                default           { $false }
            }
        }

        # Sub-level plans under an MG scope (partial/informational only)
        $subLevelPlansUnderMg = @()
        if ($scopeType -eq 'ManagementGroup') {
            $subLevelPlansUnderMg = $activePlans | Where-Object {
                $_.AppliedScopeType -eq 'Subscription' -and
                ($relevantPlans -notcontains $_)
            }
        }

        $existingSpHourly = ($relevantPlans | Measure-Object -Property HourlyCommitment -Sum).Sum
        $existingSPs      = $relevantPlans

        Write-Host "  Total active SP orders found  : $($allPlans.Count)" -ForegroundColor Green
        Write-Host "  Plans applicable to this scope: $($relevantPlans.Count)" -ForegroundColor Green
        Write-Host "  Existing hourly commitment    : $(Format-Currency $existingSpHourly)/hr" -ForegroundColor Green

        if ($relevantPlans.Count -gt 0) {
            Write-Host ""
            Write-Host ("  {0,-36} {1,8} {2,12} {3,14} {4,12} {5}" -f "Plan Name","Term","Hourly","Scope Type","Expiry Date","Applied Scope")
            Write-Host "  $('-' * 100)"
            $relevantPlans | ForEach-Object {
                $scopeDisplay = if ($_.AppliedScopes) { ($_.AppliedScopes -join ', ').Substring(0, [math]::Min(40, ($_.AppliedScopes -join ', ').Length)) } else { $_.AppliedScopeType }
                $expiryDisplay = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd') } else { 'Unknown' }
                $daysLeft = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate - (Get-Date)).Days } else { $null }
                $expiryColor = if ($null -ne $daysLeft -and $daysLeft -le 90) { 'Red' } elseif ($null -ne $daysLeft -and $daysLeft -le 180) { 'Yellow' } else { 'White' }
                Write-Host ("  {0,-36} {1,8} {2,12} {3,14} {4,12} {5}" -f `
                    $_.DisplayName, $_.Term, (Format-Currency $_.HourlyCommitment), $_.AppliedScopeType, $expiryDisplay, $scopeDisplay) `
                    -ForegroundColor $expiryColor
            }
        }

        if ($subLevelPlansUnderMg.Count -gt 0) {
            Write-Host ""
            Write-Host "  Subscription-scoped plans under this MG (informational — not summed):" -ForegroundColor DarkYellow
            $subLevelPlansUnderMg | ForEach-Object {
                $expiryDisplay = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd') } else { 'Unknown' }
                $daysLeft = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate - (Get-Date)).Days } else { $null }
                $expiryColor = if ($null -ne $daysLeft -and $daysLeft -le 90) { 'Red' } elseif ($null -ne $daysLeft -and $daysLeft -le 180) { 'Yellow' } else { 'DarkYellow' }
                Write-Host ("    {0,-36} {1,8} {2,12}  Expiry: {3}  Scope: {4}" -f `
                    $_.DisplayName, $_.Term, (Format-Currency $_.HourlyCommitment), $expiryDisplay, ($_.AppliedScopes -join ', ')) `
                    -ForegroundColor $expiryColor
            }
        }

        # Warn about plans expiring within 90 days
        $expiringPlans = $activePlans | Where-Object {
            $_.ExpiryDate -and ([datetime]$_.ExpiryDate - (Get-Date)).Days -le 90
        }
        if ($expiringPlans.Count -gt 0) {
            Write-Host ""
            Write-Host "  ⚠  WARNING: The following Savings Plans expire within 90 days and will NOT auto-renew:" -ForegroundColor Red
            $expiringPlans | ForEach-Object {
                $daysLeft = ([datetime]$_.ExpiryDate - (Get-Date)).Days
                Write-Host ("    {0,-36} Expiry: {1}  ({2} days)  Hourly: {3}" -f `
                    $_.DisplayName, ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd'), $daysLeft, (Format-Currency $_.HourlyCommitment)) -ForegroundColor Red
            }
            Write-Host "  Action: Purchase replacement SPs before expiry to avoid a coverage gap." -ForegroundColor Red
        }

    } catch {
        $spFetchWarning = $true
        Write-Host "  WARNING: Could not retrieve existing Savings Plans via BillingBenefits API." -ForegroundColor Yellow
        Write-Host "  Reason  : $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Action  : Re-run with -ManualExistingSpHourlyAUD <amount> to supply the" -ForegroundColor Yellow
        Write-Host "            existing hourly commitment manually, or grant 'Billing Reader'" -ForegroundColor Yellow
        Write-Host "            at the Billing Account scope." -ForegroundColor Yellow
        Write-Host "  Impact  : Gap analysis will treat all remaining PAYG as uncovered." -ForegroundColor Yellow
        $existingSpHourly = 0.0
    }
}
#endregion

#region ── Fetch Existing Reservations (Capacity API) ─────────────────────────
Write-Section "Fetching Existing Reservations (RIs)"

$existingRIs    = @()
$riFetchWarning = $false

try {
    $riApiUri  = "https://management.azure.com/providers/Microsoft.Capacity/reservationOrders?api-version=2022-11-01&`$expand=reservations"
    $riHeaders = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
    $riResp    = Invoke-RestMethod -Method GET -Uri $riApiUri -Headers $riHeaders

    $allRIs = @()
    $riPage = $riResp
    while ($riPage) {
        foreach ($order in $riPage.value) {
            $reservations = if ($order.PSObject.Properties['reservations']) { $order.reservations } else { @() }
            foreach ($ri in $reservations) {
                $allRIs += [PSCustomObject]@{
                    OrderId              = $order.name
                    ReservationId        = $ri.name
                    DisplayName          = $ri.properties.displayName
                    Status               = $ri.properties.provisioningState
                    Term                 = $ri.properties.term               # P1Y / P3Y
                    AppliedScopeType     = $ri.properties.appliedScopeType   # Shared / Single / ManagementGroup
                    AppliedScopes        = $ri.properties.appliedScopes      # array of scope IDs
                    Quantity             = [int]($ri.properties.quantity)
                    SkuName              = $ri.sku.name
                    ReservedResourceType = $ri.properties.reservedResourceType
                    Location             = $ri.properties.location
                    ExpiryDate           = $ri.properties.expiryDateTime
                    InstanceFlexibility  = $ri.properties.instanceFlexibility
                }
            }
        }
        $riPage = if ($riPage.nextLink) { Invoke-RestMethod -Method GET -Uri $riPage.nextLink -Headers $riHeaders } else { $null }
    }

    $activeRIs = $allRIs | Where-Object { $_.Status -eq 'Succeeded' }

    # Filter to RIs that cover this scope
    $relevantRIs = $activeRIs | Where-Object {
        $ri = $_
        switch ($ri.AppliedScopeType) {
            'Shared'          { $true }
            'ManagementGroup' { $ri.AppliedScopes | Where-Object { $_ -match [regex]::Escape($scopeId) } }
            'Single'          {
                if ($scopeType -eq 'Subscription') {
                    $ri.AppliedScopes | Where-Object { $_ -match [regex]::Escape($scopeId) }
                } else {
                    $false   # subscription-scoped RI under MG scope — informational only
                }
            }
            default           { $false }
        }
    }

    # Sub-level RIs under MG scope shown separately
    $subLevelRIsUnderMg = @()
    if ($scopeType -eq 'ManagementGroup') {
        $subLevelRIsUnderMg = $activeRIs | Where-Object {
            $_.AppliedScopeType -eq 'Single' -and ($relevantRIs -notcontains $_)
        }
    }

    $existingRIs = $relevantRIs

    Write-Host "  Total RI reservations found       : $($allRIs.Count)" -ForegroundColor Green
    Write-Host "  RIs applicable to this scope      : $($relevantRIs.Count)" -ForegroundColor Green

    if ($relevantRIs.Count -gt 0) {
        Write-Host ""
        Write-Host ("  {0,-34} {1,-22} {2,5} {3,5} {4,14} {5,12} {6}" -f "Display Name","SKU","Qty","Term","Scope Type","Expiry Date","Region")
        Write-Host "  $('-' * 110)"
        $relevantRIs | Sort-Object ExpiryDate | ForEach-Object {
            $expiryDisplay = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd') } else { 'Unknown' }
            $daysLeft      = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate - (Get-Date)).Days } else { $null }
            $color         = if ($null -ne $daysLeft -and $daysLeft -le 90)  { 'Red'    } `
                        elseif ($null -ne $daysLeft -and $daysLeft -le 180) { 'Yellow' } `
                        else                                                 { 'White'  }
            Write-Host ("  {0,-34} {1,-22} {2,5} {3,5} {4,14} {5,12} {6}" -f `
                $_.DisplayName, $_.SkuName, $_.Quantity, $_.Term, $_.AppliedScopeType, $expiryDisplay, $_.Location) `
                -ForegroundColor $color
        }
    }

    if ($subLevelRIsUnderMg.Count -gt 0) {
        Write-Host ""
        Write-Host "  Subscription-scoped RIs under this MG (informational — not aggregated):" -ForegroundColor DarkYellow
        $subLevelRIsUnderMg | Sort-Object ExpiryDate | ForEach-Object {
            $expiryDisplay = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd') } else { 'Unknown' }
            $daysLeft      = if ($_.ExpiryDate) { ([datetime]$_.ExpiryDate - (Get-Date)).Days } else { $null }
            $color         = if ($null -ne $daysLeft -and $daysLeft -le 90)  { 'Red'    } `
                        elseif ($null -ne $daysLeft -and $daysLeft -le 180) { 'Yellow' } `
                        else                                                 { 'DarkYellow' }
            Write-Host ("    {0,-34} {1,-22} Qty: {2}  {3}  Expiry: {4}  Scope: {5}" -f `
                $_.DisplayName, $_.SkuName, $_.Quantity, $_.Term, $expiryDisplay,
                ($_.AppliedScopes -join ', ')) -ForegroundColor $color
        }
    }

    # Warn about RIs expiring within 90 days
    $expiringRIs = $relevantRIs | Where-Object {
        $_.ExpiryDate -and ([datetime]$_.ExpiryDate - (Get-Date)).Days -le 90
    }
    if ($expiringRIs.Count -gt 0) {
        Write-Host ""
        Write-Host "  ⚠  WARNING: The following Reservations expire within 90 days and will NOT auto-renew:" -ForegroundColor Red
        $expiringRIs | ForEach-Object {
            $daysLeft = ([datetime]$_.ExpiryDate - (Get-Date)).Days
            Write-Host ("    {0,-34} SKU: {1,-20} Qty: {2}  Expiry: {3}  ({4} days)" -f `
                $_.DisplayName, $_.SkuName, $_.Quantity,
                ([datetime]$_.ExpiryDate).ToString('yyyy-MM-dd'), $daysLeft) -ForegroundColor Red
        }
        Write-Host "  Action: Renew or replace these reservations before expiry to avoid PAYG fallback." -ForegroundColor Red
    }

} catch {
    $riFetchWarning = $true
    Write-Host "  WARNING: Could not retrieve Reservations via Capacity API." -ForegroundColor Yellow
    Write-Host "  Reason  : $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Action  : Ensure you have 'Reservations Reader' at the billing account or" -ForegroundColor Yellow
    Write-Host "            Owner/Contributor on the individual reservations." -ForegroundColor Yellow
    Write-Host "  Impact  : RI inventory and expiry dates will not be shown." -ForegroundColor Yellow
    Write-Host "            RI spend figures from Cost Management are still used." -ForegroundColor Yellow
}
#endregion

#region ── Pull Cost Data ─────────────────────────────────────────────────────
Write-Section "Fetching Compute Cost Data from Cost Management"

$costQueryBody = @{
    type       = "ActualCost"
    timeframe  = "Custom"
    timePeriod = @{
        from = "${dateFrom}T00:00:00+00:00"
        to   = "${dateTo}T23:59:59+00:00"
    }
    dataset = @{
        granularity = "Daily"
        aggregation = @{ totalCost = @{ name = "Cost"; function = "Sum" } }
        grouping    = @(
            @{ type = "Dimension"; name = "MeterCategory" }
            @{ type = "Dimension"; name = "MeterSubCategory" }
            @{ type = "Dimension"; name = "ResourceType" }
            @{ type = "Dimension"; name = "ResourceGroupName" }
            @{ type = "Dimension"; name = "PricingModel" }
        )
        filter = @{
            or = @(
                $COMPUTE_METER_CATEGORIES | ForEach-Object {
                    @{ dimensions = @{ name = "MeterCategory"; operator = "In"; values = @($_) } }
                }
            )
        }
    }
}

# Management Group scope: also break down by subscription
$subBreakdownRows = @()
if ($scopeType -eq 'ManagementGroup') {
    $costQueryBodySub = $costQueryBody.PSObject.Copy()
    $costQueryBodySub = $costQueryBody | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $costQueryBodySub.dataset.grouping += [PSCustomObject]@{ type = "Dimension"; name = "SubscriptionId" }
    $costQueryBodySub.dataset.grouping += [PSCustomObject]@{ type = "Dimension"; name = "SubscriptionName" }
}

Write-Host "  Querying Cost Management API... (large MG scopes may take up to 30 s)" -ForegroundColor Yellow
$response = Invoke-CostManagementQuery -Scope $BillingScope -Token $token -Body $costQueryBody
Write-Host "  Rows returned: $($response.properties.rows.Count)" -ForegroundColor Green
#endregion

#region ── Parse Cost Response ────────────────────────────────────────────────
$cols = $response.properties.columns | Select-Object -ExpandProperty name

$rawRows = $response.properties.rows | ForEach-Object {
    $row = $_; $obj = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $obj[$cols[$i]] = $row[$i] }
    [PSCustomObject]$obj
}

$paygRows        = $rawRows | Where-Object { $_.PricingModel -in @('OnDemand', 'PAYG', '') }
$spCoveredRows   = $rawRows | Where-Object { $_.PricingModel -eq 'SavingsPlan' }
$riCoveredRows   = $rawRows | Where-Object { $_.PricingModel -eq 'Reservation' }

if ($paygRows.Count -eq 0) {
    Write-Host "`n  No PAYG compute rows found. All compute may already be committed." -ForegroundColor Green
    exit 0
}
#endregion

#region ── Aggregate ──────────────────────────────────────────────────────────
$totalPAYG          = ($paygRows      | Measure-Object -Property Cost -Sum).Sum
$totalSPCovered     = ($spCoveredRows | Measure-Object -Property Cost -Sum).Sum   # at discounted rate
$totalRICovered     = ($riCoveredRows | Measure-Object -Property Cost -Sum).Sum   # at discounted rate

# Convert SP-covered discounted cost back to PAYG-equivalent (for full baseline picture)
# We use the average of 1-yr and 3-yr discount as a conservative approximation
$avgSpDiscount      = ($SP_DISCOUNT_1YR + $SP_DISCOUNT_3YR) / 2
$spCoveredPAYGEquiv = $totalSPCovered / (1 - $avgSpDiscount)

$totalComputeAllPricing = $totalPAYG + $totalSPCovered + $totalRICovered

# Daily PAYG cost series
$dailyCosts = $paygRows | Group-Object UsageDate | ForEach-Object {
    [PSCustomObject]@{
        Date      = $_.Name
        DailyCost = ($_.Group | Measure-Object -Property Cost -Sum).Sum
    }
} | Sort-Object Date

$avgDailyCost  = ($dailyCosts | Measure-Object -Property DailyCost -Average).Average
$minDailyCost  = ($dailyCosts | Measure-Object -Property DailyCost -Minimum).Minimum
$maxDailyCost  = ($dailyCosts | Measure-Object -Property DailyCost -Maximum).Maximum
$avgHourlyPAYG = $avgDailyCost / 24

# Percentile baselines
$sortedDaily   = $dailyCosts.DailyCost | Sort-Object
function Get-Percentile ([double[]]$Sorted, [int]$Pct) {
    $idx = [math]::Max(0, [math]::Floor($Sorted.Count * $Pct / 100) - 1)
    return $Sorted[$idx]
}
$p30Daily = Get-Percentile $sortedDaily 30
$p50Daily = Get-Percentile $sortedDaily 50
$p70Daily = Get-Percentile $sortedDaily 70

$p30Hourly = $p30Daily / 24
$p50Hourly = $p50Daily / 24
$p70Hourly = $p70Daily / 24

# By meter category (PAYG only)
$byCategory = $paygRows | Group-Object MeterCategory | ForEach-Object {
    [PSCustomObject]@{
        MeterCategory = $_.Name
        TotalCost     = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        Percentage    = (($_.Group | Measure-Object -Property Cost -Sum).Sum / $totalPAYG) * 100
    }
} | Sort-Object TotalCost -Descending

# By resource group (PAYG, top 15)
$byRG = $paygRows | Group-Object ResourceGroupName | ForEach-Object {
    [PSCustomObject]@{
        ResourceGroup = $_.Name
        TotalCost     = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        Percentage    = (($_.Group | Measure-Object -Property Cost -Sum).Sum / $totalPAYG) * 100
    }
} | Sort-Object TotalCost -Descending | Select-Object -First 15

# RI spend breakdown (from Cost Management RI rows)
$riByCategory = $riCoveredRows | Group-Object MeterCategory | ForEach-Object {
    [PSCustomObject]@{
        MeterCategory = $_.Name
        TotalCost     = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        Percentage    = if ($totalRICovered -gt 0) { (($_.Group | Measure-Object -Property Cost -Sum).Sum / $totalRICovered) * 100 } else { 0 }
    }
} | Sort-Object TotalCost -Descending

$riByRG = $riCoveredRows | Group-Object ResourceGroupName | ForEach-Object {
    [PSCustomObject]@{
        ResourceGroup = $_.Name
        TotalCost     = ($_.Group | Measure-Object -Property Cost -Sum).Sum
        Percentage    = if ($totalRICovered -gt 0) { (($_.Group | Measure-Object -Property Cost -Sum).Sum / $totalRICovered) * 100 } else { 0 }
    }
} | Sort-Object TotalCost -Descending | Select-Object -First 10

# RI PAYG-equivalent: convert RI discounted spend back to estimated PAYG-equivalent
$avgRiDiscount      = ($RI_DISCOUNT_1YR + $RI_DISCOUNT_3YR) / 2
$riCoveredPAYGEquiv = if ($totalRICovered -gt 0) { $totalRICovered / (1 - $avgRiDiscount) } else { 0 }

# Total estimated PAYG-equivalent across all pricing models (for coverage % reporting)
$totalComputePAYGEquiv = $totalPAYG + $spCoveredPAYGEquiv + $riCoveredPAYGEquiv
#endregion

#region ── GAP Calculation ────────────────────────────────────────────────────
# GAP = remaining PAYG baseline that is NOT already covered by an active SP.
# Existing SP commitments reduce the effective PAYG baseline that needs new coverage.
#
# Logic:
#   The existing SP hourly commitment already "earns" at the SP discount rate
#   against the compute spend. What remains on PAYG is the gap.
#   We compare at the P30/P50/P70 hourly baselines.

$gapP30Hourly = [math]::Max(0, $p30Hourly - $existingSpHourly)
$gapP50Hourly = [math]::Max(0, $p50Hourly - $existingSpHourly)
$gapP70Hourly = [math]::Max(0, $p70Hourly - $existingSpHourly)

$existingCoverageOfP50Pct = if ($p50Hourly -gt 0) {
    [math]::Min(100, ($existingSpHourly / $p50Hourly) * 100)
} else { 100 }

$annualPAYGProjected = ($totalPAYG / $LookbackDays) * 365

function Get-SpModel ([string]$Label, [double]$GapHourly, [double]$AvgHourly) {
    $annualCommit    = $GapHourly * 8760
    $coverageFrac    = if ($AvgHourly -gt 0) { [math]::Min($GapHourly / $AvgHourly, 1.0) } else { 0 }
    $coveredAnnual   = $annualPAYGProjected * $coverageFrac
    $saving1yr       = $coveredAnnual * $SP_DISCOUNT_1YR
    $saving3yr       = $coveredAnnual * $SP_DISCOUNT_3YR

    [PSCustomObject]@{
        Scenario             = $Label
        GapHourly            = $GapHourly
        AnnualCommitment     = $annualCommit
        CoverageOfPAYG_Pct   = $coverageFrac * 100
        EstSaving_1Yr        = $saving1yr
        EstSaving_3Yr        = $saving3yr
        Payback_1Yr_Months   = if ($saving1yr -gt 0) { [math]::Round($annualCommit / ($saving1yr / 12), 1) } else { 999 }
        Payback_3Yr_Months   = if ($saving3yr -gt 0) { [math]::Round($annualCommit / ($saving3yr / 12), 1) } else { 999 }
    }
}

$gapModels = @(
    (Get-SpModel "Conservative – P30 gap" $gapP30Hourly $avgHourlyPAYG)
    (Get-SpModel "Moderate   – P50 gap" $gapP50Hourly $avgHourlyPAYG)
    (Get-SpModel "Aggressive – P70 gap" $gapP70Hourly $avgHourlyPAYG)
)
#endregion

#region ── Report ─────────────────────────────────────────────────────────────
Write-Section "Executive Summary — Compute Cost Coverage"
Write-Host ""
Write-Host "  Scope Type                       : $scopeType  [$scopeId]"
Write-Host "  Lookback Period                  : $LookbackDays days ($dateFrom → $dateTo)"
Write-Host ""
Write-Host "  ── Compute Spend Breakdown (all pricing models) ──"
Write-Host ("  Total Compute (PAYG + SP + RI)   : {0}" -f (Format-Currency $totalComputeAllPricing))
Write-Host ("  ├─ PAYG (OnDemand) — uncovered   : {0}  ({1:N1}%)" -f `
    (Format-Currency $totalPAYG), (100 * $totalPAYG / [math]::Max(1,$totalComputeAllPricing)))
Write-Host ("  ├─ Savings Plan covered          : {0}  ({1:N1}%)  ≈ {2} PAYG-equiv" -f `
    (Format-Currency $totalSPCovered),
    (100 * $totalSPCovered / [math]::Max(1,$totalComputeAllPricing)),
    (Format-Currency $spCoveredPAYGEquiv)) -ForegroundColor $(if ($totalSPCovered -gt 0) { 'Green' } else { 'White' })
Write-Host ("  └─ Reservation covered           : {0}  ({1:N1}%)  ≈ {2} PAYG-equiv" -f `
    (Format-Currency $totalRICovered),
    (100 * $totalRICovered / [math]::Max(1,$totalComputeAllPricing)),
    (Format-Currency $riCoveredPAYGEquiv)) -ForegroundColor $(if ($totalRICovered -gt 0) { 'Green' } else { 'White' })
Write-Host ""
Write-Host "  ── PAYG Hourly Baseline Analysis ──"
Write-Host ("  Average Hourly PAYG              : {0}/hr" -f (Format-Currency $avgHourlyPAYG))
Write-Host ("  P30 Hourly (Conservative anchor) : {0}/hr" -f (Format-Currency $p30Hourly))
Write-Host ("  P50 Hourly (Moderate anchor)     : {0}/hr" -f (Format-Currency $p50Hourly))
Write-Host ("  P70 Hourly (Aggressive anchor)   : {0}/hr" -f (Format-Currency $p70Hourly))
Write-Host ""
Write-Host "  ── Existing Savings Plan Position ──"
if ($spFetchWarning) {
    Write-Host "  Existing SP Hourly Commitment    : UNKNOWN (API access insufficient)" -ForegroundColor Yellow
} else {
    Write-Host ("  Existing SP Hourly Commitment    : {0}/hr  ({1} active plan(s))" -f `
        (Format-Currency $existingSpHourly), $existingSPs.Count) -ForegroundColor $(if ($existingSpHourly -gt 0) { 'Green' } else { 'DarkYellow' })
    Write-Host ("  Coverage of P50 Baseline         : {0:N1}%  {1}" -f `
        $existingCoverageOfP50Pct, (Get-PercentageBar $existingCoverageOfP50Pct))
    $soonestSpExpiry = $existingSPs | Where-Object { $_.ExpiryDate } | Sort-Object { [datetime]$_.ExpiryDate } | Select-Object -First 1
    if ($soonestSpExpiry) {
        $spDaysLeft = ([datetime]$soonestSpExpiry.ExpiryDate - (Get-Date)).Days
        $spExpiryColor = if ($spDaysLeft -le 90) { 'Red' } elseif ($spDaysLeft -le 180) { 'Yellow' } else { 'Green' }
        Write-Host ("  Earliest SP Expiry               : {0}  ({1} days)" -f `
            ([datetime]$soonestSpExpiry.ExpiryDate).ToString('yyyy-MM-dd'), $spDaysLeft) -ForegroundColor $spExpiryColor
    }
}
Write-Host ""
Write-Host "  ── Existing Reservation (RI) Position ──"
if ($riFetchWarning) {
    Write-Host "  RI inventory                     : UNKNOWN (API access insufficient)" -ForegroundColor Yellow
    Write-Host ("  RI Covered Spend (Cost Mgmt)     : {0}  [at discounted rate]" -f (Format-Currency $totalRICovered))
} else {
    Write-Host ("  Active RIs (scope-applicable)    : {0} reservation(s)" -f $existingRIs.Count) `
        -ForegroundColor $(if ($existingRIs.Count -gt 0) { 'Green' } else { 'DarkYellow' })
    Write-Host ("  RI Covered Spend (Cost Mgmt)     : {0}  [at discounted rate]" -f (Format-Currency $totalRICovered)) `
        -ForegroundColor $(if ($totalRICovered -gt 0) { 'Green' } else { 'White' })
    $soonestRiExpiry = $existingRIs | Where-Object { $_.ExpiryDate } | Sort-Object { [datetime]$_.ExpiryDate } | Select-Object -First 1
    if ($soonestRiExpiry) {
        $riDaysLeft = ([datetime]$soonestRiExpiry.ExpiryDate - (Get-Date)).Days
        $riExpiryColor = if ($riDaysLeft -le 90) { 'Red' } elseif ($riDaysLeft -le 180) { 'Yellow' } else { 'Green' }
        Write-Host ("  Earliest RI Expiry               : {0}  ({1} days)" -f `
            ([datetime]$soonestRiExpiry.ExpiryDate).ToString('yyyy-MM-dd'), $riDaysLeft) -ForegroundColor $riExpiryColor
    }
}
Write-Host ""
Write-Host "  ── Remaining GAP (Opportunity for Additional Savings Plans) ──"
Write-Host ("  P30 Hourly Gap                   : {0}/hr" -f (Format-Currency $gapP30Hourly)) -ForegroundColor $(if ($gapP30Hourly -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("  P50 Hourly Gap                   : {0}/hr" -f (Format-Currency $gapP50Hourly)) -ForegroundColor $(if ($gapP50Hourly -gt 0) { 'Yellow' } else { 'Green' })
Write-Host ("  P70 Hourly Gap                   : {0}/hr" -f (Format-Currency $gapP70Hourly)) -ForegroundColor $(if ($gapP70Hourly -gt 0) { 'Yellow' } else { 'Green' })

Write-Section "PAYG Compute by Meter Category"
$byCategory | ForEach-Object {
    Write-Host ("  {0,-35} {1,12}   {2}" -f $_.MeterCategory, (Format-Currency $_.TotalCost), (Get-PercentageBar $_.Percentage))
}

Write-Section "Top Resource Groups by PAYG Compute"
$byRG | ForEach-Object {
    Write-Host ("  {0,-42} {1,12}   {2:N1}%" -f $_.ResourceGroup, (Format-Currency $_.TotalCost), $_.Percentage)
}

Write-Section "Reservation (RI) Coverage — Spend Breakdown"
if ($totalRICovered -eq 0) {
    Write-Host "  No Reservation-covered compute spend found in this period." -ForegroundColor DarkYellow
} else {
    Write-Host ("  Total RI-Covered Spend (discounted rate) : {0}" -f (Format-Currency $totalRICovered))
    Write-Host ("  Est. PAYG-Equivalent (before discount)   : {0}  [avg {1:N0}% RI discount applied]" -f `
        (Format-Currency $riCoveredPAYGEquiv), ($avgRiDiscount * 100))
    Write-Host ""
    if ($riByCategory.Count -gt 0) {
        Write-Host "  By Meter Category:"
        $riByCategory | ForEach-Object {
            Write-Host ("    {0,-35} {1,12}   {2}" -f $_.MeterCategory, (Format-Currency $_.TotalCost), (Get-PercentageBar $_.Percentage))
        }
    }
    if ($riByRG.Count -gt 0) {
        Write-Host ""
        Write-Host "  Top Resource Groups (RI spend):"
        $riByRG | ForEach-Object {
            Write-Host ("    {0,-42} {1,12}   {2:N1}%" -f $_.ResourceGroup, (Format-Currency $_.TotalCost), $_.Percentage)
        }
    }
    Write-Host ""
    Write-Host "  Note: RI-covered rows in Cost Management show the discounted (post-RI) rate." -ForegroundColor DarkGray
    Write-Host "  Discount rates vary by VM SKU, region, and term. Verify actual rates in the" -ForegroundColor DarkGray
    Write-Host "  Azure Portal → Reservations → select reservation → Utilization." -ForegroundColor DarkGray
}

Write-Section "Additional Savings Plan Gap Model"
Write-Host ""
Write-Host "  These scenarios show what you would ADDITIONALLY commit to cover the remaining"
Write-Host "  PAYG gap after netting off your existing SP hourly commitment of $(Format-Currency $existingSpHourly)/hr."
Write-Host ""
Write-Host ("  {0,-28} {1,14} {2,20} {3,14} {4,14} {5,14}" -f `
    "Scenario", "Gap /hr", "New Annual Commit", "PAYG Coverage", "1-Yr Saving", "3-Yr Saving")
Write-Host "  $('-' * 108)"

foreach ($m in $gapModels) {
    $noGapFlag = if ($m.GapHourly -le 0) { ' ✓ Fully covered' } else { '' }
    Write-Host ("  {0,-28} {1,14} {2,20} {3,12:N1}% {4,14} {5,14}{6}" -f `
        $m.Scenario,
        (Format-Currency $m.GapHourly),
        (Format-Currency $m.AnnualCommitment),
        $m.CoverageOfPAYG_Pct,
        (Format-Currency $m.EstSaving_1Yr),
        (Format-Currency $m.EstSaving_3Yr),
        $noGapFlag) `
        -ForegroundColor $(if ($m.GapHourly -le 0) { 'Green' } else { 'White' })
}

Write-Host ""
Write-Host "  Discount rates: 1-Year ~$([int]($SP_DISCOUNT_1YR*100))%  |  3-Year ~$([int]($SP_DISCOUNT_3YR*100))%  vs PAYG (indicative)" -ForegroundColor DarkGray
Write-Host "  Actual rates vary by VM family, region and negotiated agreement." -ForegroundColor DarkGray

Write-Section "How Scope Affects Savings Plan Purchase"
Write-Host ""
if ($scopeType -eq 'ManagementGroup') {
    Write-Host "  You queried at Management Group scope. When purchasing additional SPs:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Option A — Management Group scope SP (recommended for most flexibility)"
    Write-Host "    • One purchasing action covers all child subscriptions in the MG."
    Write-Host "    • Purchase in Azure Portal → Cost Management → Savings Plans → Purchase"
    Write-Host "      and select 'Management Group' as the applied scope."
    Write-Host "    • Benefit applies automatically across any subscription in the MG."
    Write-Host ""
    Write-Host "  Option B — Per-subscription SP (use when child subs have different owners)"
    Write-Host "    • Repeat the analysis per subscription using -BillingScope '/subscriptions/<id>'"
    Write-Host "    • Set applied scope to 'Subscription' when purchasing."
    Write-Host ""
    Write-Host "  Option C — Shared scope SP"
    Write-Host "    • Applies across all subscriptions in the entire billing account."
    Write-Host "    • Offers maximum flexibility but requires Billing Account-level purchase."
} else {
    Write-Host "  You queried at Subscription scope. When purchasing additional SPs:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Option A — Subscription scope SP"
    Write-Host "    • SP benefit applies only to this subscription."
    Write-Host "    • Purchase in Azure Portal → Cost Management → Savings Plans → Purchase"
    Write-Host "      and select 'Subscription' as the applied scope."
    Write-Host ""
    Write-Host "  Option B — Shared or Management Group scope SP"
    Write-Host "    • If this sub sits under an MG, buy at MG level to share the benefit"
    Write-Host "      across sibling subscriptions and avoid over-committing on this sub alone."
    Write-Host "    • Re-run this script at the MG scope for a consolidated view."
}

Write-Section "Recommended Next Steps"
Write-Host ""
$bestGap = $gapModels[0]   # Conservative P30 gap
if ($bestGap.GapHourly -le 0) {
    Write-Host "  Your existing Savings Plans already cover the conservative (P30) baseline." -ForegroundColor Green
    Write-Host "  Consider whether to extend to P50 or P70 coverage or let SPs expire first."
} else {
    Write-Host "  Suggested additional hourly commitment : $(Format-Currency $bestGap.GapHourly)/hr  (P30 Conservative)" -ForegroundColor Green
    Write-Host "  Estimated additional 1-Year saving    : $(Format-Currency $bestGap.EstSaving_1Yr)"
    Write-Host "  Estimated additional 3-Year saving    : $(Format-Currency $bestGap.EstSaving_3Yr)"
}
Write-Host ""
Write-Host "  1. Validate in Azure Portal: Cost Management → Savings Plans → Purchase"
Write-Host "     → Use the built-in 'Recommendations' tab for Microsoft's own suggestion."
Write-Host "  2. Check Azure Advisor → Cost recommendations for Savings Plan alerts."
Write-Host "  3. Review existing SP expiry dates and plan renewal before they lapse."
Write-Host "  4. Review existing RI expiry dates: Azure Portal → Reservations → filter Expiry."
Write-Host "     Plan RI renewals 60-90 days in advance (procurement lead-time)."
Write-Host "  5. For new RI opportunities: Azure Portal → Cost Management → Reservations"
Write-Host "     → 'Purchase recommendations' tab → filter by VM SKU + region."
Write-Host "  6. SPs and RIs coexist: use RIs for stable, predictable SKU+region workloads;"
Write-Host "     SPs for flexible or mixed-size compute that moves across regions/SKUs."
#endregion

#region ── CSV Export ─────────────────────────────────────────────────────────
if ($OutputCsvPath) {
    Write-Section "Exporting Data"
    $paygPath  = "${OutputCsvPath}_PAYG_Detail.csv"
    $modelPath = "${OutputCsvPath}_Gap_Model.csv"
    $spPath    = "${OutputCsvPath}_ExistingSPs.csv"
    $riPath    = "${OutputCsvPath}_ExistingRIs.csv"
    $riSpendPath = "${OutputCsvPath}_RI_Spend_Detail.csv"

    $paygRows  | Export-Csv -Path $paygPath  -NoTypeInformation -Encoding UTF8
    $gapModels | Export-Csv -Path $modelPath -NoTypeInformation -Encoding UTF8
    if ($existingSPs.Count -gt 0) { $existingSPs | Export-Csv -Path $spPath -NoTypeInformation -Encoding UTF8 }
    if ($existingRIs.Count -gt 0) { $existingRIs | Export-Csv -Path $riPath -NoTypeInformation -Encoding UTF8 }
    if ($riCoveredRows.Count -gt 0) { $riCoveredRows | Export-Csv -Path $riSpendPath -NoTypeInformation -Encoding UTF8 }

    Write-Host "  PAYG detail       → $paygPath"  -ForegroundColor Green
    Write-Host "  Gap model         → $modelPath" -ForegroundColor Green
    if ($existingSPs.Count -gt 0)    { Write-Host "  Existing SPs      → $spPath" -ForegroundColor Green }
    if ($existingRIs.Count -gt 0)    { Write-Host "  Existing RIs      → $riPath" -ForegroundColor Green }
    if ($riCoveredRows.Count -gt 0)  { Write-Host "  RI spend detail   → $riSpendPath" -ForegroundColor Green }
}
#endregion

Write-Host "`nAnalysis complete.`n" -ForegroundColor Green

