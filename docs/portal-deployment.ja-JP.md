# Azure ポータルでの手動デプロイ手順（`deploy.ps1` 相当）

このドキュメントは、`deploy.ps1` が Azure CLI で自動作成するのと**同じ構成**を、Azure ポータル（GUI）から手動で作成する手順をまとめたものです。スクリプトを使わずに構成を理解したい場合や、GUI で1つずつ確認しながら作りたい場合に利用してください。

作成される構成の全体像は以下のアーキテクチャ図を参照してください。

<img src="images/architecture-diagram.png" alt="アーキテクチャ図: リソースグループ、Container Apps 環境（GPU ワークロードプロファイル）、Ollama と nginx 認証プロキシの 2 コンテナを含む Container App" width="600">

> **どちらを使うべきか**: 起動コマンド（複数行のシェルスクリプト）の入力は、ポータルよりも `deploy.ps1`（または `az` CLI）の方が確実です。ポータルは学習・確認用途に向いています。本番運用や繰り返し利用は `deploy.ps1` を推奨します。

---

## 作成するリソース（`deploy.ps1` と同一）

| リソース | 名前（既定値） | 補足 |
|---|---|---|
| リソースグループ | `rg-ollama-gptoss20b` | |
| Container Apps 環境 | `cae-ollama-gptoss20b` | ワークロードプロファイル環境 |
| GPU ワークロードプロファイル | `Consumption-GPU-NC8as-T4` | T4（8 vCPU / 56 GiB）。A100 は `Consumption-GPU-NC24-A100` |
| Container App | `ca-ollama-gptoss20b` | 1レプリカ内に2コンテナ |
| └ コンテナ1（GPU） | `ollama` | `docker.io/ollama/ollama:latest`、ポート 11434 |
| └ コンテナ2（サイドカー） | `auth-proxy` | `nginx:alpine`、ポート 8080、APIキー検証 |
| シークレット | `api-key` | APIキー値を保持 |

- **リージョン**: `West US 3`（westus3）または `Sweden Central`（swedencentral）のいずれか。どちらも T4 / A100 対応。
- **イングレス**: 外部公開・ターゲットポート **8080**（＝ auth-proxy）。Ollama の 11434 は直接公開しない。
- **スケール**: 最小レプリカ **0** / 最大レプリカ **1**（アイドル時はゼロスケール）。

---

## 前提条件

1. Azure サブスクリプションと、リソース作成権限（共同作成者など）。
2. **サーバーレス GPU のクォータ**。サブスクリプションによっては T4/A100 のクォータ申請が必要です。不足している場合は「使用量 + クォータ」から増加申請してください。
3. 対応リージョン（West US 3 / Sweden Central）を使用すること。
4. 事前に **APIキー文字列**を1つ決めておく（例: ランダムな英数字32文字）。`deploy.ps1` は自動生成しますが、ポータル手動作成では自分で用意します。

---

## 手順

### Step 1. リソースグループの作成

1. ポータル上部の検索から「リソース グループ」→「作成」。
2. **リソースグループ名**: `rg-ollama-gptoss20b`
3. **リージョン**: `West US 3`（または `Sweden Central`）
4. 「確認および作成」→「作成」。

### Step 2. Container Apps 環境の作成

1. 検索から「Container Apps」→「作成」。
2. 「基本」タブ:
   - **リソースグループ**: `rg-ollama-gptoss20b`
   - **コンテナーアプリ名**: いったん `ca-ollama-gptoss20b`（環境作成のためアプリも同時に作れます。後で編集します）
   - **リージョン**: `West US 3`
3. 「Container Apps 環境」の「新規作成」:
   - **環境名**: `cae-ollama-gptoss20b`
   - **環境の種類**: **ワークロード プロファイル**（GPU に必須。従量課金の Consumption 専用環境では GPU/ExpressRoute 非対応）
   - Log Analytics ワークスペースは自動作成でOK
4. まだ「作成」は押さず、次の Step 3 でGPUプロファイルを追加します（環境作成後でも追加可）。

> 環境を先に作ってしまった場合でも、Step 3 は環境の「ワークロード プロファイル」から後追加できます。

### Step 3. GPU ワークロードプロファイルの追加

1. Container Apps **環境**（`cae-ollama-gptoss20b`）を開く →「**ワークロード プロファイル**」。
2. 「追加」で新規プロファイル:
   - **名前**: `Consumption-GPU-NC8as-T4`
   - **種類**: GPU 系の Consumption プロファイル（`NC8as-T4` = T4）を選択
   - ※ Consumption プロファイルなのでノード数（最小/最大）は指定不要・非対応
3. 保存。

### Step 4. Container App の構成

Container App（`ca-ollama-gptoss20b`）を開き、「**リビジョンとレプリカ**」→「新しいリビジョンの作成」で以下を構成します（新規作成ウィザードでも同様）。

#### 4-1. シークレットの登録

1. アプリの「設定」→「シークレット」→「追加」。
2. **キー**: `api-key` / **値**: 用意したAPIキー文字列。

#### 4-2. コンテナ1: Ollama（**先頭に定義すること**）

> **重要**: GPU は「Container App 内で最初に定義されたコンテナ」に割り当てられます。**Ollama を必ず1つ目**に定義してください。

- **名前**: `ollama`
- **イメージソース**: Docker Hub など → **イメージ**: `docker.io/ollama/ollama:latest`
- **ワークロードプロファイル**: `Consumption-GPU-NC8as-T4`（GPU）
- **CPU / メモリ**: 7.5 vCPU / 55 Gi（プロファイル上限 8/56 から auth-proxy 用の 0.5/1 を引いた残り）
- **環境変数**: `OLLAMA_MODEL` = `gpt-oss:20b`
- **コマンドのオーバーライド**: `sh,-c`（コマンド = `sh`、引数の先頭 = `-c`）
- **引数のオーバーライド**: 下記「Ollama 起動スクリプト」を**1つの引数**として貼り付け

#### 4-3. コンテナ2: auth-proxy（nginx サイドカー）

- **名前**: `auth-proxy`
- **イメージ**: `nginx:alpine`
- **CPU / メモリ**: 0.5 vCPU / 1 Gi
- **環境変数**: `API_KEY` = シークレット参照（`api-key`）
- **コマンドのオーバーライド**: `sh,-c`
- **引数のオーバーライド**: 下記「nginx 起動スクリプト」を**1つの引数**として貼り付け（`__API_KEY__` を実際のAPIキー値に置換）

> **落とし穴（`sh -c` の二重ネスト）**: コマンドに `sh -c` を指定するので、引数側のスクリプトには `sh -c '...'` を**含めない**でください（本体だけを貼る）。二重にすると起動時にクラッシュループします。

#### 4-4. イングレス

1. 「イングレス」→ **有効**。
2. **トラフィック**: 「どこからでもトラフィックを受け入れます」（external）。
3. **ターゲットポート**: **8080**（auth-proxy のポート。11434 ではない）。

#### 4-5. スケール

- **最小レプリカ数**: `0`
- **最大レプリカ数**: `1`

作成/リビジョン反映を実行します。

### Step 5. モデルのロード確認

- Ollama コンテナ起動時に `ollama pull gpt-oss:20b` → `ollama run` が自動実行されます（約13GBのダウンロードのため数分かかります）。
- 「リビジョンとレプリカ」でレプリカの **実行の状態** が正常（Running）になること、または「ログ」でエラーが無いことを確認します。
- `ollama pull` が失敗するとレプリカが再起動を繰り返し、状態が `Failed`/`Degraded` になります。

### Step 6. エンドポイントの取得と疎通確認

1. アプリ「概要」の **アプリケーション URL**（`https://<app>.<region>.azurecontainerapps.io`）を控える。
2. Windows PowerShell から（`curl` エイリアスではなく **`curl.exe`**、JSON の `"` は `\"` エスケープ）:

```powershell
curl.exe -X POST "https://<app>.<region>.azurecontainerapps.io/api/generate" -H "X-API-Key: <YOUR_API_KEY>" -H "Content-Type: application/json" -d '{\"model\":\"gpt-oss:20b\",\"prompt\":\"Hello\",\"stream\":false}'
```

APIキーが欠落/不一致のリクエストは auth-proxy から `401` が返り、Ollama へは転送されません。

---

## コピペ用: 起動スクリプト（引数オーバーライドに貼る本体）

### Ollama 起動スクリプト（コンテナ1の引数）

```sh
ollama serve &
until ollama list >/dev/null 2>&1; do sleep 2; done
ollama pull "gpt-oss:20b" || exit 1
echo "" | ollama run "gpt-oss:20b" >/tmp/ollama-run.log 2>&1
wait
```

> **ヘルスチェックに注意**: 公式 `ollama/ollama` イメージには `curl` が同梱されていません。`curl` でのヘルスチェックは "command not found" で失敗するため、`ollama list` を使います。
> モデル名を変える場合は、`OLLAMA_MODEL` 環境変数と、このスクリプト内の 2 箇所の `"gpt-oss:20b"` を同じ名前に合わせてください。

### nginx 起動スクリプト（コンテナ2の引数、`__API_KEY__` を実キーに置換）

```sh
cat <<'EOF' > /etc/nginx/conf.d/default.conf
server {
    listen 8080;
    location / {
        if ($http_x_api_key = "") { return 401; }
        if ($http_x_api_key != "__API_KEY__") { return 401; }
        proxy_pass http://localhost:11434;
        proxy_set_header Host $host;
    }
}
EOF
nginx -g "daemon off;"
```

> ヒアドキュメント終端子を `<<'EOF'`（引用符付き）にすることで、`$http_x_api_key`・`$host`（nginx変数）がシェルに展開されず、nginx が解釈するリテラルとして書き込まれます。

---

## 注意点・落とし穴（実機検証で判明したもの）

- **GPU はコンテナ配列の先頭に割り当てられる** → Ollama を1つ目に定義する。
- **`curl` 非同梱** → Ollama のヘルスチェックは `ollama list` を使う。
- **`sh -c` の二重ネスト回避** → コマンドに `sh,-c`、引数はスクリプト**本体のみ**。
- **ターゲットポートは 8080**（auth-proxy）。11434 を公開しない。
- **リージョン/GPU** は West US 3・Sweden Central × T4・A100 のみ想定。
- **改行コード**: ポータルで直接入力する場合は LF/CRLF を意識する必要は基本ありませんが、コピペ元にCRLFが混じると Linux コンテナ側で `\r` がコマンドに混入し得ます。うまく起動しない場合は改行を疑ってください（`deploy.ps1` は LF へ正規化しています）。
- **コスト**: `Consumption-GPU-*` は稼働秒数のみ課金（アイドル時はゼロスケールで課金停止）。詳細は [README.ja-JP.md](../README.ja-JP.md) の「課金」節を参照。

---

## モデルの変更

`OLLAMA_MODEL` 環境変数と Ollama 起動スクリプト内のモデル名を変更すれば、他モデルも動きます（GPUのVRAMに載る範囲）。指定できるモデル例・VRAM目安は [README.ja-JP.md](../README.ja-JP.md) の「モデルの変更」節、または [.env.ja-JP.example](../.env.ja-JP.example) を参照してください。

---

## `deploy.ps1` との対応

| このガイドの手順 | `deploy.ps1` の該当処理 |
|---|---|
| Step 1 リソースグループ | `az group create`（`Initialize-ResourceGroup`） |
| Step 2 環境作成 | `az containerapp env create`（`Initialize-ContainerAppsEnvironment`） |
| Step 3 GPUプロファイル | `az containerapp env workload-profile add`（`Add-GpuWorkloadProfile`） |
| Step 4 アプリ構成 | `az rest --method PUT`（`Publish-ContainerApp` + `New-ContainerAppSpec`） |
| 起動スクリプト | `OllamaStartup.psm1` / `NginxConfig.psm1` |
| Step 5 モデル確認 | `properties.runningStatus` ポーリング（`Wait-ForModelReady`） |
| Step 6 エンドポイント | `properties.configuration.ingress.fqdn`（`Get-PublicEndpointUrl`） |

自動化された全体フロー・設計の詳細は [.kiro/specs/ollama-gpt-oss-container-apps/design.md](../.kiro/specs/ollama-gpt-oss-container-apps/design.md) を参照してください。

---

*For the English version, see [portal-deployment.md](portal-deployment.md).*
