# Container Apps 仕様まとめ

> このドキュメントは `.kiro/specs/ollama-gpt-oss-container-apps/requirements.md` および `design.md` に定義された、本プロジェクトの最終的な実装仕様を要約したリファレンスである。手順の詳細な説明は `README.md` / `README.ja-JP.md` を参照。

## 構成概要

Resource_Group の中に、GPUワークロードプロファイルを持つ Container Apps Environment を作成し、その中に単一の Container App（1レプリカ、`minReplicas: 0` / `maxReplicas: 1`）を配置する。Container App は同一レプリカ内に2つのコンテナを持つ。

1. **Ollama コンテナ**（`docker.io/ollama/ollama:latest`、ポート11434、GPU割当）— Container Apps はコンテナ配列の先頭に定義されたコンテナにGPUアクセス権を与えるため、`properties.template.containers[0]` に配置する。
2. **Auth-proxy コンテナ**（nginx公式イメージ、ポート8080）— サイドカーとして2番目に定義する。同一レプリカ内は同一ネットワーク名前空間を共有するため `http://localhost:11434` でOllamaコンテナへ転送する。

イングレスは `external: true` / `targetPort: 8080` で auth-proxy コンテナへルーティングし、Ollamaの11434ポートは外部に直接公開しない。

```
Resource Group
└─ Container Apps Environment (GPUワークロードプロファイル)
   └─ Container App (1レプリカ)
      ├─ [0] ollama container  (ollama/ollama:latest, :11434, GPU)
      └─ [1] auth-proxy container (nginx, :8080) --localhost:11434--> ollama
Internet --HTTPS + X-API-Key--> ingress(:8080) --> auth-proxy
```

## .envパラメータ一覧

| キー | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `AZURE_SUBSCRIPTION_ID` | ○ | (なし) | サブスクリプションID |
| `AZURE_TENANT_ID` | ○ | (なし) | テナントID |
| `AZURE_RESOURCE_GROUP` | ○ | `rg-ollama-gptoss20b` | リソースグループ名 |
| `AZURE_LOCATION` | ○ | `westus3` | `westus3` または `swedencentral` |
| `AZURE_CONTAINER_APPS_ENVIRONMENT` | ○ | `cae-ollama-gptoss20b` | Container Apps環境名 |
| `AZURE_CONTAINER_APP_NAME` | ○ | `ca-ollama-gptoss20b` | Container App名 |
| `AZURE_GPU_TYPE` | ○ | `T4` | `T4` または `A100` |
| `OLLAMA_MODEL` | ○ | `gpt-oss:20b` | pull/run対象モデル名 |
| `API_KEY` | × | (自動生成) | 未設定時はdeploy.ps1が自動生成し`.env`へ書き込む |

必須項目（`API_KEY`以外）が欠落している場合、`deploy.ps1`は欠落項目名を表示して処理を中断する。

## GPU/リージョン対応表

対応リージョンは `westus3` と `swedencentral` の2つのみで、両リージョンとも `T4` / `A100` の両GPU種別に対応する（4組み合わせすべて許可）。

| リージョン | T4 | A100 |
|---|---|---|
| `westus3` | ✅ | ✅ |
| `swedencentral` | ✅ | ✅ |

GPU種別からワークロードプロファイルへのマッピング：

| GPU_Type | ワークロードプロファイルタイプ | vCPU/メモリ上限 |
|---|---|---|
| `T4` | `Consumption-GPU-NC8as-T4` | 8 vCPU / 56 GiB |
| `A100` | `Consumption-GPU-NC24-A100` | 24 vCPU / 220 GiB |

この検証は仕様上の許可判定であり、Azure側の実際のクォータ/キャパシティを事前確認するものではない。非対応の組み合わせが指定された場合はエラーを表示して中断する。

## デプロイフロー

`deploy.ps1` は以下の順序で処理を行う。

1. `az account show` で認証済みセッションを確認（未ログインならエラー表示して中断。ログイン処理自体は代行しない）
2. `.env` を読込・必須項目を検証（欠落があればエラー表示して中断）。`API_KEY`が未設定なら自動生成して`.env`へ書き込み、処理を継続
3. 現在のサブスクリプションIDと`.env`の値が異なる場合、確認なしで`az account set --subscription`により切替
4. `az group create` でResource_Groupを作成（既存なら再利用、Azure CLI自体が冪等）
5. リージョン×GPU_Typeの組み合わせを検証（非対応ならエラー表示して中断）
6. Container_Apps_Environmentを作成/再利用し、GPUワークロードプロファイルを追加/再利用
7. Container_Appのスペック（YAML）を生成し、存在確認後に`az containerapp create`または`update`を実行（`update`失敗時もエラーをログに記録し後続手順を継続）
8. Public_EndpointのURLをコンソールに表示（GPU割当や後続手順の成否に関わらず表示）
9. `ollama pull`/`ollama run`の進行をポーリングしてモデル準備状態を確認（失敗・タイムアウトならエラー表示して中断）
10. 成功時、APIキーとURLを使ったcurl実行例をコンソールに表示

## APIキー認証方式

Ollama自体にはAPIキー認証機能がないため、auth-proxyサイドカー（nginx公式イメージ）がリクエストヘッダーを検証してからOllamaコンテナへ転送する。

- 起動コマンドがヒアドキュメントでAPIキー値をリテラルとして埋め込んだ`nginx.conf`をコンテナ起動時に生成し、`nginx -g "daemon off;"`を実行する（動的な文字列比較ロジックは不要）
- `X-API-Key`ヘッダーが**欠落**している場合 → 401を応答（一致判定は行わない）
- `X-API-Key`ヘッダーの値が設定済みAPIキーと**一致しない**場合 → 401を応答
- `X-API-Key`ヘッダーの値が設定済みAPIキーと**完全一致**する場合のみ → `http://localhost:11434`（Ollamaコンテナ）へ転送

## クリーンアップ手順

`teardown.ps1` によりリソースを削除する。

1. `.env`から`AZURE_RESOURCE_GROUP`を読込
2. `-Force`スイッチが指定されない限り、削除実行前に`Read-Host`で確認入力を要求
3. `az group delete --name <rg> --yes --no-wait`を実行（非同期削除、完了はAzure側で背景実行）
4. 権限エラーやAPIエラーで削除が失敗した場合、**再試行せず**失敗内容を表示して終了
