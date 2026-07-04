# Ollama gpt-oss:20b on Azure Container Apps (Serverless GPU)

Deploy [Ollama](https://ollama.com/) running the `gpt-oss:20b` model on [Azure Container Apps' serverless GPU](https://learn.microsoft.com/azure/container-apps/gpu-serverless-overview) workload profile, fully automated via Azure CLI and a single PowerShell script.

The Container App runs two containers in the same replica:

- **Ollama container** (`ollama/ollama:latest`) — loads and serves the `gpt-oss:20b` model on port `11434`, with GPU access.
- **Auth proxy container** (nginx official image) — a sidecar that sits in front of Ollama. Ollama itself has no API key support, so this nginx sidecar validates the `X-API-Key` request header and only forwards the request to the Ollama container (via `localhost:11434`) when the key matches. The public ingress points at the nginx sidecar, not directly at Ollama.

This means every request to the public endpoint must include a valid API key, even though Ollama has no built-in authentication.

<img src="docs/images/architecture-diagram.png" alt="Architecture diagram: resource group, Container Apps environment (GPU workload profile), and the Container App with the Ollama and nginx auth-proxy containers" width="600">

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

### Choosing the model

This deployment is model-agnostic: set `OLLAMA_MODEL` in `.env` to any model tag available at [ollama.com/library](https://ollama.com/library) and redeploy — the startup command runs `ollama pull` / `ollama run` for whatever you specify. The auth proxy, API key, and `chat.py` all work unchanged with any model.

The only real constraint is GPU VRAM. The T4 profile has 16 GB and the A100 profile has 80 GB; set `AZURE_GPU_TYPE` accordingly. Approximate fit (Q4 quantization):

| Model size | VRAM (approx) | T4 (16 GB) | A100 (80 GB) |
|---|---|:---:|:---:|
| 7B (e.g. `qwen2.5:7b`) | ~5 GB | ✅ | ✅ |
| 14B (`qwen2.5:14b`) | ~9 GB | ✅ | ✅ |
| `gpt-oss:20b` (default) | ~13 GB | ✅ (tight) | ✅ |
| 30–32B (`qwen3:30b`) | ~18–22 GB | ❌ | ✅ |
| 70–72B (`qwen2.5:72b`) | ~40–45 GB | ❌ | ✅ |
| Kimi K2 (1T-param MoE) | hundreds of GB | ❌ | ❌ (too large) |

Examples you can set: `gpt-oss:20b` (default), `qwen3:8b`, `qwen2.5:7b`, `qwen2.5:14b`, `qwen2.5-coder:7b`, `qwen3:30b` (A100), `qwen2.5:72b` (A100), `gemma3`, `llama3.1`, etc.

Note: after switching models, the first request triggers a cold start (the new model is pulled and loaded), so it can take a while.

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

## Private access over a private endpoint (optional, advanced)

By default this deployment exposes a **public** HTTPS endpoint protected by the API key (see [Usage](#usage)). If you instead need to reach the app privately — for example from on-premises over **ExpressRoute** or from within an Azure VNet — you can put the Container Apps environment behind a **private endpoint**. This is configured on the **environment**, not on the app's ingress, and is **not automated by `deploy.ps1`**.

Key facts (verified against current Azure docs):

- **A custom domain is NOT required.** You can keep the app's default FQDN (`<app>.<region>.azurecontainerapps.io`); it only needs to resolve to the private endpoint's private IP via a **private DNS zone**. A custom domain is relevant only if you want your own hostname (for an apex/A-record custom domain you point it at the private endpoint IP; a CNAME custom domain is unchanged).
- Private endpoints are supported on **workload profiles environments** (the type this project creates) and **do not require the environment to be VNet-integrated**.
- The app's ingress can stay **external**; disabling public network access at the **environment** level is what makes access private.
- **Internal (VNet/ILB) environments** can only be selected at environment creation time. For this already-created external environment, the **private endpoint** approach is the way to add private access without recreating it.

Where to configure it (Azure portal):

1. Open the **Container Apps environment** (`cae-ollama-gptoss20b`) → **Networking**.
2. Set **Public network access** to **Disabled**. A **Private endpoint** section then appears. (Once a private endpoint is configured, public access cannot be re-enabled — the two are mutually exclusive.)
3. Under **Private endpoint**, add one:
   - Place it in your **VNet + subnet** (the subnet must be **/27 or larger**).
   - Enable **private DNS zone** integration so the default FQDN resolves to the private IP.

Prerequisites for actual use:

- An Azure **VNet + subnet (/27 or larger)** to host the private endpoint.
- For on-premises access: an **ExpressRoute** circuit with **private peering**, a connection to that VNet, and on-premises DNS able to resolve the private DNS zone (e.g. via a DNS forwarder).

Caveats:

- Disabling public network access **blocks internet access** — the public `curl` / `chat.py` examples above will no longer reach the app except from within the VNet or over ExpressRoute. Set up the VNet, private endpoint, DNS, and connectivity **before** disabling public access, or you will lock yourself out.
- The API-key auth-proxy remains in place regardless, giving you defense in depth.

See [Use a private endpoint with an Azure Container Apps environment](https://learn.microsoft.com/en-us/azure/container-apps/how-to-use-private-endpoint) and [Configure Private Endpoints and DNS for Virtual Networks in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/private-endpoints-with-dns).

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
