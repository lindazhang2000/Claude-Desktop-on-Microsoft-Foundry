<#
.SYNOPSIS
  Registers an Entra ID app for Claude Desktop "Gateway SSO" and wires the
  required APIM Named values (entra-tenant-id, entra-client-id).

.DESCRIPTION
  - Creates app registration "Claude Cowork gateway" as a single-tenant,
    public (PKCE) client with the Mobile-and-desktop redirect URI
    http://127.0.0.1/callback (exactly as the Claude docs require).
  - Idempotent: re-running updates the same app instead of creating duplicates.
  - Pushes APIM Named values used by the validate-jwt policy.

.NOTES
  Requires: Azure CLI (az), already logged in.
            Account must be allowed to create App registrations in the tenant
            and be Contributor on the APIM resource.

  Configuration is loaded from a .env file at the repo root (or whatever
  -EnvFile points at). See .env.example for the required keys. Any parameter
  passed on the command line overrides the .env value.
#>

[CmdletBinding()]
param(
  [string] $EnvFile        = (Join-Path $PSScriptRoot '..\.env'),
  [string] $TenantId,
  [string] $SubscriptionId,
  [string] $ResourceGroup,
  [string] $ApimName,
  [string] $AppDisplayName,
  [string] $RedirectUri
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

# Parameter > .env value > error
function Resolve-Setting($paramValue, $envKey) {
  if ($paramValue) { return $paramValue }
  if ($envMap.ContainsKey($envKey) -and $envMap[$envKey]) { return $envMap[$envKey] }
  throw "Setting '$envKey' missing: pass it as a parameter or set it in $EnvFile."
}

$TenantId       = Resolve-Setting $TenantId       'TENANT_ID'
$SubscriptionId = Resolve-Setting $SubscriptionId 'SUBSCRIPTION_ID'
$ResourceGroup  = Resolve-Setting $ResourceGroup  'RESOURCE_GROUP'
$ApimName       = Resolve-Setting $ApimName       'APIM_NAME'
$AppDisplayName = Resolve-Setting $AppDisplayName 'APP_DISPLAY_NAME'
$RedirectUri    = Resolve-Setting $RedirectUri    'REDIRECT_URI'

Require-Cmd az

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

# Sanity-check tenant matches
$currentTenant = az account show --query tenantId -o tsv
if ($currentTenant -ne $TenantId) {
  Write-Warning "Current az tenant ($currentTenant) does not match -TenantId ($TenantId)."
  Write-Warning "Run: az login --tenant $TenantId    then re-run this script."
  throw "Tenant mismatch"
}

# -----------------------------------------------------------------------------
# 1. App registration (idempotent)
# -----------------------------------------------------------------------------
Write-Host "==> Looking up existing app '$AppDisplayName'" -ForegroundColor Cyan
$appId = az ad app list --display-name $AppDisplayName --query "[0].appId" -o tsv

if ([string]::IsNullOrWhiteSpace($appId)) {
  Write-Host "    Not found. Creating app registration..." -ForegroundColor Yellow
  $appId = az ad app create `
    --display-name $AppDisplayName `
    --sign-in-audience AzureADMyOrg `
    --query appId -o tsv
  Write-Host "    Created appId = $appId" -ForegroundColor Green
} else {
  Write-Host "    Found existing appId = $appId" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 2. Configure as public (PKCE) client with Mobile/Desktop redirect URI.
#    The Graph 'publicClient.redirectUris' slot is the "Mobile and desktop
#    applications" platform Claude requires (it's the only platform Entra
#    allows to use any local loopback port).
# -----------------------------------------------------------------------------
Write-Host "==> Updating publicClient redirect URI and PKCE flow" -ForegroundColor Cyan

$objectId = az ad app show --id $appId --query id -o tsv

$patchBody = @{
  publicClient = @{
    redirectUris = @($RedirectUri)
  }
  isFallbackPublicClient = $true
} | ConvertTo-Json -Depth 5 -Compress

# PATCH via Microsoft Graph (az ad app update does not expose isFallbackPublicClient cleanly)
$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $patchBody -Encoding utf8
try {
  az rest --method PATCH `
          --uri "https://graph.microsoft.com/v1.0/applications/$objectId" `
          --headers "Content-Type=application/json" `
          --body "@$tmp" | Out-Null
} finally {
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------------------
# 3. Ensure a service principal exists in this tenant (needed for sign-in)
# -----------------------------------------------------------------------------
Write-Host "==> Ensuring service principal exists" -ForegroundColor Cyan
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if ([string]::IsNullOrWhiteSpace($spId)) {
  $spId = az ad sp create --id $appId --query id -o tsv
  Write-Host "    Created SP $spId" -ForegroundColor Green
} else {
  Write-Host "    SP already exists ($spId)" -ForegroundColor Green
}

# -----------------------------------------------------------------------------
# 4. Push APIM Named values used by validate-jwt
# -----------------------------------------------------------------------------
Write-Host "==> Upserting APIM Named values on $ApimName" -ForegroundColor Cyan

function Set-ApimNamedValue($name, $value) {
  $exists = az apim nv show --resource-group $ResourceGroup --service-name $ApimName --named-value-id $name 2>$null
  if ($LASTEXITCODE -eq 0 -and $exists) {
    az apim nv update --resource-group $ResourceGroup --service-name $ApimName `
      --named-value-id $name --value $value | Out-Null
    Write-Host "    Updated $name" -ForegroundColor Green
  } else {
    az apim nv create --resource-group $ResourceGroup --service-name $ApimName `
      --named-value-id $name --display-name $name --value $value --secret false | Out-Null
    Write-Host "    Created $name" -ForegroundColor Green
  }
}

Set-ApimNamedValue 'entra-tenant-id' $TenantId
Set-ApimNamedValue 'entra-client-id' $appId

# -----------------------------------------------------------------------------
# 5. Summary + next-step values for Claude Desktop
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "========== DONE ==========" -ForegroundColor Cyan
Write-Host "Tenant ID  : $TenantId"
Write-Host "Client ID  : $appId"
Write-Host "Redirect   : $RedirectUri"
Write-Host ""
Write-Host "Claude Desktop -> Configure third-party inference:" -ForegroundColor Yellow
Write-Host "  Gateway base URL : https://$ApimName.azure-api.net/claude"
Write-Host "  Credential kind  : Interactive sign-in"
Write-Host "  Client ID        : $appId"
Write-Host "  Issuer URL       : https://login.microsoftonline.com/$TenantId/v2.0"
Write-Host "  Scopes / Port    : (leave empty)"
Write-Host ""
Write-Host "APIM validate-jwt policy will reference {{entra-tenant-id}} and {{entra-client-id}}." -ForegroundColor Yellow
