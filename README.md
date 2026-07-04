# Ollama gpt-oss:20b on Azure Container Apps (Serverless GPU)

Deploy [Ollama](https://ollama.com/) running the `gpt-oss:20b` model on [Azure Container Apps' serverless GPU](https://learn.microsoft.com/azure/container-apps/gpu-serverless-overview) workload profile, fully automated via Azure CLI and a single PowerShell script.

The Container App runs two containers in the same replica:

- **Ollama container** (`ollama/ollama:latest`) — loads and serves the `gpt-oss:20b` model on port `11434`, with GPU access.
- **Auth proxy container** (nginx official image) — a sidecar that sits in front of Ollama. Ollama itself has no API key support, so this nginx sidecar validates the `X-API-Key` request header and only forwards the request to the Ollama container (via `localhost:11434`) when the key matches. The public ingress points at the nginx sidecar, not directly at Ollama.

This means every request to the public endpoint must include a valid API key, even though Ollama has no built-in authentication.

> 日本語版は [README.ja-JP.md](README.ja-JP.md) を参照してください。

## Prerequisites

Before running `deploy.ps1`, complete the following steps:

1. **Install the Azure CLI** if you haven't already (see the comments at the top of `.env.example` for a `winget` install command).

2. **Sign in to Azure yourself, once, before running the script.**
   Run interactive login manually:

   ```powershell
   az login
   ```

   `deploy.ps1` does **not** perform this login on your behalf. It only checks whether an authenticated session already exists (`az account show`). If you have not logged in, the script will print an error and abort immediately — it will not prompt you to log in interactively.

3. **Copy `.env.example` to `.env` and edit the values**:

   ```powershell
   Copy-Item .env.example .env
   ```

   Then edit `.env` and fill in the following keys:

   | Key | Required | Description |
   |---|---|---|
   | `AZURE_SUBSCRIPTION_ID` | Yes | Target Azure subscription GUID. Check with `az account show --query id -o tsv`. |
   | `AZURE_TENANT_ID` | Yes | Target Azure AD (Microsoft Entra ID) tenant GUID. Check with `az account show --query tenantId -o tsv`. |
   | `AZURE_RESOURCE_GROUP` | Yes (has a default) | Resource group that holds all resources. Reused if it already exists. |
   | `AZURE_LOCATION` | Yes (has a default) | Deployment region. Must be `westus3` or `swedencentral`. |
   | `AZURE_CONTAINER_APPS_ENVIRONMENT` | Yes (has a default) | Name of the Container Apps Environment (GPU workload profile). |
   | `AZURE_CONTAINER_APP_NAME` | Yes (has a default) | Name of the Container App (Ollama + auth-proxy sidecar). |
   | `AZURE_GPU_TYPE` | Yes (has a default) | GPU type. Must be `T4` or `A100`. |
   | `OLLAMA_MODEL` | Yes (has a default) | Model name used as the target for `ollama pull` / `ollama run`. |
   | `API_KEY` | No | Secret string required in the `X-API-Key` header. If left empty, `deploy.ps1` generates a random value and writes it back into `.env`. |

   If any required key (other than `API_KEY`) is missing, `deploy.ps1` will report the missing key names and abort.

4. **(Optional, contributors only)** If you plan to modify the PowerShell modules in `modules/`, the test suite uses [Pester](https://pester.dev/). Pester is not required to simply deploy — it's only needed if you want to run or extend the tests in `tests/`.

## Deployment

Once the prerequisites above are done, run:

```powershell
.\deploy.ps1
```

This script will, in order:

1. Verify you have an authenticated Azure CLI session (abort with an error if not).
2. Read and validate `.env`, generating and saving a random `API_KEY` if it was left empty.
3. Switch the active Azure CLI subscription to the one specified in `.env` if it differs from the current context (no confirmation prompt).
4. Create the resource group (`AZURE_RESOURCE_GROUP`), reusing it if it already exists.
5. Validate the `AZURE_LOCATION` / `AZURE_GPU_TYPE` combination, then create (or reuse) the Container Apps Environment and add the matching GPU workload profile.
6. Create (or update, if it already exists) the Container App containing the Ollama container and the nginx auth-proxy sidecar, with ingress routed to the auth-proxy on port 8080.
7. Print the public endpoint URL as soon as the Container App is created — this happens regardless of whether later steps succeed.
8. Poll the Container App until the model has finished loading (`ollama pull` / `ollama run` inside the Ollama container's startup command), aborting with an error on failure or timeout.
9. Print a ready-to-use `curl` example once the model is confirmed ready, and write the endpoint URL/API key/model name/curl example to `result-endpoint.md` (used by the bundled `chat.py` client, see [Usage](#usage) below).

Supported region / GPU combinations:

| Region | T4 | A100 |
|---|---|---|
| `westus3` | ✅ | ✅ |
| `swedencentral` | ✅ | ✅ |

Any other region/GPU combination is rejected before any Azure resources are created.

Re-running `.\deploy.ps1` is safe: existing resources (resource group, environment, workload profile, Container App) are reused/updated rather than recreated.

## Usage

`deploy.ps1` writes the public endpoint URL, API key, model name, and (once the model is ready) a `curl` example to `result-endpoint.md` in the project root. This file contains a secret (the API key) and is excluded from version control via `.gitignore`.

You can call the endpoint directly with `curl`:

```powershell
curl -X POST "$Url/api/generate" -H "X-API-Key: $ApiKey" -H "Content-Type: application/json" -d '{"model":"gpt-oss:20b","prompt":"Hello"}'
```

Replace `$Url` with the public endpoint printed by `deploy.ps1` and `$ApiKey` with the value of `API_KEY` in your `.env` file. Requests without a valid `X-API-Key` header (missing or mismatched) receive a `401` response from the auth-proxy sidecar and are never forwarded to Ollama.

### Chat client (`chat.py`)

For a quick text-only interactive chat, use the bundled `chat.py` script. It reads `result-endpoint.md` and talks to the `/api/generate` endpoint. It requires only Python 3.8+ (standard library only, no `pip install` needed):

```powershell
python chat.py
```

Type your prompt and press Enter; type `exit` or `quit` (or press Ctrl+C) to end the session. Useful options:

```powershell
python chat.py --file path\to\result-endpoint.md   # use a different result file
python chat.py --no-stream                          # wait for the full response instead of streaming
python chat.py --timeout 180                        # increase the HTTP timeout (seconds)
```

Note: the Container App scales to zero replicas when idle (`minReplicas: 0`). After a period of inactivity, the first request after a cold start may take longer while the container restarts and the model reloads.

## Billing

This deployment is designed to cost (almost) nothing while idle:

- **Serverless GPU, pay-per-use.** The Container App uses a Consumption serverless GPU workload profile (e.g. `Consumption-GPU-NC8as-T4`). You are billed per second only for the time replicas are actively running (vCPU-seconds, memory GiB-seconds, and GPU-seconds). Serverless GPU has no "idle" charge.
- **Scales to zero when idle.** The app is configured with `minReplicas: 0` and the default `cooldownPeriod` of 300 seconds. About 5 minutes after the last request to the public ingress, the replica scales to zero and GPU/compute billing stops entirely. (Azure CLI management commands such as `az containerapp show` do not count as traffic and do not reset the cooldown.)
- **No standing storage cost for keeping the container.** No persistent volume (e.g. Azure Files) is provisioned. The container images are pulled from the public Docker registry (no paid Azure Container Registry), and the `gpt-oss:20b` model (~13 GB) is re-downloaded into ephemeral storage on each cold start rather than persisted — so there is no storage charge for "keeping" the container. The trade-off is a slower first request after a scale-to-zero (the model is re-pulled and reloaded).
- **Minor residual costs.** The Container Apps Environment's Log Analytics workspace can incur small log ingestion/retention charges regardless of replica activity. This is negligible compared to GPU compute.

To guarantee zero ongoing cost, delete the resources with `teardown.ps1` (see [Cleanup](#cleanup) below).

See [Billing in Azure Container Apps](https://learn.microsoft.com/azure/container-apps/billing) and [Using serverless GPUs](https://learn.microsoft.com/azure/container-apps/gpu-serverless-overview) for details.

## Cleanup

To delete the resources created by `deploy.ps1`, run:

```powershell
.\teardown.ps1
```

By default this prompts for confirmation (`y`/`N`) before deleting the resource group specified in `.env` (`AZURE_RESOURCE_GROUP`). To skip the confirmation prompt:

```powershell
.\teardown.ps1 -Force
```

The script deletes the entire resource group (`az group delete --yes --no-wait`), which removes the Container Apps Environment and Container App along with it. Deletion is issued asynchronously (`--no-wait`); actual completion happens in the background on Azure's side. If deletion fails (e.g. a permissions or API error), the script reports the failure and exits without retrying.
