<#
.SYNOPSIS
  Provisions an Azure API Management (APIM) service to act as the gateway
  in front of Microsoft Foundry. Run this once if you don't already have
  an APIM instance.

.DESCRIPTION
  - Creates the resource group (if it doesn't exist).
  - Creates the APIM service (if it doesn't exist).
  - Defaults to the Consumption tier so provisioning takes a few minutes
    instead of the 30-45 minutes a Developer/Basic tier needs. Override
    with -ApimSku or APIM_SKU in .env when you want a dedicated tier.
  - Idempotent: re-running it just verifies state and prints the gateway URL.

  After this script finishes, follow the rest of the README:
    1. (Optional) Run scripts/register-claude-entra-app.ps1.
    2. Add the Anthropic API + foundry-key Named value in the portal
       (Steps 2-4 of the blog), or wire them up via your own automation.

.NOTES
  Requires: Azure CLI (az), already logged in (`az login --tenant <id>`).
            Account must be Contributor on the subscription (or at least
            on the target resource group).

  Configuration is loaded from a .env file at the repo root (or whatever
  -EnvFile points at). See .env.example for the required keys. Any
  parameter passed on the command line overrides the .env value.
#>

[CmdletBinding()]
param(
  [string] $EnvFile        = (Join-Path $PSScriptRoot '..\.env'),
  [string] $SubscriptionId,
  [string] $ResourceGroup,
  [string] $Location,
  [string] $ApimName,
  [ValidateSet('Consumption','Developer','Basic','Standard','Premium')]
  [string] $ApimSku,
  [string] $PublisherEmail,
  [string] $PublisherName
)

$ErrorActionPreference = 'Stop'

function Require-Cmd($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command '$name' not found in PATH."
  }
}

# -----------------------------------------------------------------------------
# 0. Load .env (simple KEY=VALUE parser; ignores blanks and # comments)
# -----------------------------------------------------------------------------
function Import-DotEnv($path) {
  if (-not (Test-Path $path)) {
    throw ".env file not found at '$path'. Copy .env.example to .env and fill it in."
  }
  $map = @{}
  Get-Content $path | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { return }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { return }
    $k = $line.Substring(0, $eq).Trim()
    $v = $line.Substring($eq + 1).Trim().Trim('"').Trim("'")
    $map[$k] = $v
  }
  return $map
}

$envMap = Import-DotEnv $EnvFile

function Resolve-Setting($paramValue, $envKey, [string]$default = $null) {
  if ($paramValue) { return $paramValue }
  if ($envMap.ContainsKey($envKey) -and $envMap[$envKey]) { return $envMap[$envKey] }
  if ($null -ne $default) { return $default }
  throw "Setting '$envKey' missing: pass it as a parameter or set it in $EnvFile."
}

$SubscriptionId = Resolve-Setting $SubscriptionId 'SUBSCRIPTION_ID'
$ResourceGroup  = Resolve-Setting $ResourceGroup  'RESOURCE_GROUP'
$Location       = Resolve-Setting $Location       'LOCATION'
$ApimName       = Resolve-Setting $ApimName       'APIM_NAME'
$ApimSku        = Resolve-Setting $ApimSku        'APIM_SKU'        'Consumption'
$PublisherEmail = Resolve-Setting $PublisherEmail 'APIM_PUBLISHER_EMAIL'
$PublisherName  = Resolve-Setting $PublisherName  'APIM_PUBLISHER_NAME' 'Claude Gateway Admin'

Require-Cmd az

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

# -----------------------------------------------------------------------------
# 1. Resource group
# -----------------------------------------------------------------------------
Write-Host "==> Ensuring resource group '$ResourceGroup' in '$Location'" -ForegroundColor Cyan
$rgExists = az group exists --name $ResourceGroup
if ($rgExists -eq 'true') {
  Write-Host "    Resource group already exists." -ForegroundColor Green
} else {
  az group create --name $ResourceGroup --location $Location | Out-Null
  Write-Host "    Created resource group." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 2. APIM service (idempotent)
# -----------------------------------------------------------------------------
Write-Host "==> Looking up APIM service '$ApimName'" -ForegroundColor Cyan
$existing = az apim show --name $ApimName --resource-group $ResourceGroup --only-show-errors 2>$null
if ($LASTEXITCODE -eq 0 -and $existing) {
  $existingSku = az apim show --name $ApimName --resource-group $ResourceGroup `
                  --query 'sku.name' -o tsv
  Write-Host "    APIM service already exists (SKU: $existingSku). Skipping create." -ForegroundColor Green
} else {
  Write-Host "    Not found. Creating APIM '$ApimName' (SKU: $ApimSku)..." -ForegroundColor Yellow
  if ($ApimSku -eq 'Consumption') {
    Write-Host "    Consumption tier usually provisions in a few minutes." -ForegroundColor Yellow
  } else {
    Write-Host "    $ApimSku tier provisioning typically takes 30-45 minutes. Be patient." -ForegroundColor Yellow
  }

  az apim create `
    --name $ApimName `
    --resource-group $ResourceGroup `
    --location $Location `
    --publisher-email $PublisherEmail `
    --publisher-name $PublisherName `
    --sku-name $ApimSku | Out-Null

  Write-Host "    APIM '$ApimName' created." -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 3. Summary
# -----------------------------------------------------------------------------
$gatewayUrl = az apim show --name $ApimName --resource-group $ResourceGroup `
                --query 'gatewayUrl' -o tsv

Write-Host ""
Write-Host "========== DONE ==========" -ForegroundColor Cyan
Write-Host "Resource group : $ResourceGroup"
Write-Host "Location       : $Location"
Write-Host "APIM name      : $ApimName"
Write-Host "APIM SKU       : $ApimSku"
Write-Host "Gateway URL    : $gatewayUrl"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. (Optional) Run scripts/register-claude-entra-app.ps1 to register"
Write-Host "     the Entra app and seed entra-tenant-id / entra-client-id Named values."
Write-Host "  2. In the portal, add the Anthropic API + operations (blog Step 2),"
Write-Host "     add the foundry-key Named value (blog Step 3), and paste the"
Write-Host "     inbound policy (blog Step 4)."
