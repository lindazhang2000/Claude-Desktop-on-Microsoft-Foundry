# Claude Desktop → APIM → Microsoft Foundry (Entra ID SSO)

Reference setup that puts **Azure API Management** in front of an **Anthropic Claude** deployment running on **Microsoft Foundry**, with **Entra ID single sign-on** for Claude Desktop users.

```
Claude Desktop  ──Entra ID bearer──▶  APIM  ──x-api-key──▶  Foundry /anthropic
   (per-user OIDC sign-in)         (validate-jwt)        (Claude model)
```

- End users sign in with their corporate Entra ID account (MFA + Conditional Access apply).
- The Foundry API key lives only inside APIM as a secret Named value — never on user devices.
- APIM `validate-jwt` rejects any token whose `aud` claim isn't the Entra app you register here.

## Repo layout

| Path | What it is |
|---|---|
| [scripts/register-claude-entra-app.ps1](scripts/register-claude-entra-app.ps1) | Idempotent PowerShell that creates the Entra app registration for Claude Desktop and seeds the APIM Named values (`entra-tenant-id`, `entra-client-id`). |
| [blog/claude-desktop-entra-apim-foundry.md](blog/claude-desktop-entra-apim-foundry.md) | Full walkthrough with screenshots, the inbound policy XML, the Claude Desktop config table, and the gotchas we hit. |
| `.env.example` | Template for the values the script needs. Copy to `.env`, fill in real values. |
| `.env` | Your local secrets. **Gitignored** — never commit. |
| `.gitignore` | Excludes `.env*` (keeps `.env.example`). |

## Prerequisites

- **Azure subscription** with an APIM instance and a Foundry / AI Services account that has a Claude deployment.
- Permission to register applications in your Entra tenant.
- **Claude Desktop 1.5.0** or later.
- **Azure CLI** (`az`) installed and logged in to the right tenant.
- **PowerShell 7+** (works on Windows / macOS / Linux).

## Quick start

```powershell
# 1. Copy the template and fill in your real values
Copy-Item .env.example .env
notepad .env

# 2. Log in to the correct tenant
az login --tenant <your-tenant-id>

# 3. Register the Entra app and push APIM Named values
.\scripts\register-claude-entra-app.ps1
```

The script prints the new app's **Client ID**. You'll paste that into Claude Desktop in step 5 of the blog.

After the script succeeds, follow the blog from **Step 2** onward to:
1. Create the APIM API and operations (`POST /v1/messages`, `GET /v1/models`).
2. Add the Foundry API key as a Named value (`foundry-key`).
3. Paste the `validate-jwt` + `set-backend-service` inbound policy.
4. Configure Claude Desktop.

## Configuration reference

`.env` keys (see [.env.example](.env.example)):

| Key | Purpose |
|---|---|
| `TENANT_ID` | Entra tenant the gateway app lives in |
| `SUBSCRIPTION_ID` | Azure subscription that owns APIM + Foundry |
| `RESOURCE_GROUP` | RG containing the APIM service |
| `APIM_NAME` | API Management service name |
| `FOUNDRY_ACCOUNT` | Foundry / AI Services account name |
| `FOUNDRY_DEPLOYMENT` | Claude deployment name on Foundry |
| `APP_DISPLAY_NAME` | Display name for the Entra app registration |
| `REDIRECT_URI` | Loopback redirect URI (default `http://127.0.0.1/callback`) |

CLI parameters on the script override `.env` values.

## Useful links

- [Gateway single sign-on with your identity provider — Claude.ai Documentation](https://claude.com/docs/cowork/3p/gateway-sso)
- [Configure Claude Desktop with Foundry Models — Microsoft Learn](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/configure-claude-desktop)

## Security notes

- `.env` is **not** committed. Verify with `git status` before pushing.
- The Foundry API key is **never** in this repo; it's only in the APIM `foundry-key` Named value.
- If a real value accidentally lands in Git history, rotate it (Foundry → Keys → Regenerate) and clean history with `git filter-repo` or BFG.
