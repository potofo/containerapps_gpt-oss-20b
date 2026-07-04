# Ollama gpt-oss:20b on Azure Container Apps (Serverless GPU)

[Ollama](https://ollama.com/) 上で `gpt-oss:20b` モデルを [Azure Container Apps のサーバーレス GPU](https://learn.microsoft.com/azure/container-apps/gpu-serverless-overview) ワークロードプロファイルにデプロイします。Azure CLI と単一の PowerShell スクリプトにより、デプロイ手順は完全に自動化されています。

Container App は同一レプリカ内で2つのコンテナを実行します。

- **Ollama コンテナ**（`ollama/ollama:latest`）— `gpt-oss:20b` モデルをロードし、GPU を利用してポート `11434` で提供します。
- **認証プロキシコンテナ**（nginx公式イメージ）— Ollama の手前に配置されるサイドカーです。Ollama 自体には API キー機能がないため、この nginx サイドカーが `X-API-Key` リクエストヘッダーを検証し、キーが一致した場合のみ（`localhost:11434` 経由で）Ollama コンテナへリクエストを転送します。公開イングレスは Ollama に直接ではなく、この nginx サイドカーに向けられています。

つまり、Ollama 自体には認証機能が組み込まれていないにもかかわらず、公開エンドポイントへのすべてのリクエストは有効な API キーを含む必要があります。

> For the English version, see [README.md](README.md).

## 事前準備

`deploy.ps1` を実行する前に、以下の手順を完了してください。

1. **Azure CLI をインストールする**（未インストールの場合）。`.env.example` の先頭コメントに `winget` を使ったインストールコマンドの例があります。

2. **スクリプトを実行する前に、あなた自身の手で一度だけ Azure にサインインしてください。**
   対話型ログインを手動で実行します。

   ```powershell
   az login
   ```

   `deploy.ps1` は **このログイン処理を代行しません**。スクリプトが行うのは、認証済みセッションが既に存在するかどうかの確認（`az account show`）だけです。ログインしていない場合、スクリプトはエラーを表示してただちに中断します。対話的なログインを促すことはありません。

3. **`.env.example` を `.env` にコピーし、値を編集する**:

   ```powershell
   Copy-Item .env.example .env
   ```

   続いて `.env` を編集し、以下の各キーを設定します。

   | キー | 必須 | 説明 |
   |---|---|---|
   | `AZURE_SUBSCRIPTION_ID` | 必須 | 対象の Azure サブスクリプション GUID。`az account show --query id -o tsv` で確認できます。 |
   | `AZURE_TENANT_ID` | 必須 | 対象の Azure AD（Microsoft Entra ID）テナント GUID。`az account show --query tenantId -o tsv` で確認できます。 |
   | `AZURE_RESOURCE_GROUP` | 必須（既定値あり） | すべてのリソースを保持するリソースグループ。既に存在する場合は再利用されます。 |
   | `AZURE_LOCATION` | 必須（既定値あり） | デプロイ先リージョン。`westus3` または `swedencentral` のいずれかである必要があります。 |
   | `AZURE_CONTAINER_APPS_ENVIRONMENT` | 必須（既定値あり） | Container Apps Environment（GPU ワークロードプロファイル）の名前。 |
   | `AZURE_CONTAINER_APP_NAME` | 必須（既定値あり） | Container App（Ollama + 認証プロキシサイドカー）の名前。 |
   | `AZURE_GPU_TYPE` | 必須（既定値あり） | GPU 種別。`T4` または `A100` のいずれかである必要があります。 |
   | `OLLAMA_MODEL` | 必須（既定値あり） | `ollama pull` / `ollama run` の対象となるモデル名。 |
   | `API_KEY` | 任意 | `X-API-Key` ヘッダーに必要となる秘密文字列。空のままにしておくと、`deploy.ps1` がランダムな値を生成し `.env` に書き戻します。 |

   `API_KEY` 以外の必須キーが1つでも欠けている場合、`deploy.ps1` は欠落しているキー名を報告して中断します。

4. **（任意・コントリビューター向け）** `modules/` 内の PowerShell モジュールを変更する予定がある場合、テストスイートは [Pester](https://pester.dev/) を使用しています。単にデプロイするだけであれば Pester は不要です。`tests/` 内のテストを実行・拡張したい場合にのみ必要です。

## デプロイ

上記の事前準備が完了したら、以下を実行します。

```powershell
.\deploy.ps1
```

このスクリプトは、以下の順序で処理を行います。

1. Azure CLI の認証済みセッションが存在することを確認します（存在しない場合はエラーを表示して中断します）。
2. `.env` を読み込み検証します。`API_KEY` が空の場合はランダムな値を生成して保存します。
3. 現在アクティブな Azure CLI のサブスクリプションが `.env` で指定されたものと異なる場合、確認プロンプトなしで切り替えます。
4. リソースグループ（`AZURE_RESOURCE_GROUP`）を作成します。既に存在する場合は再利用します。
5. `AZURE_LOCATION` / `AZURE_GPU_TYPE` の組み合わせを検証し、Container Apps Environment を作成（または再利用）して、対応する GPU ワークロードプロファイルを追加します。
6. Ollama コンテナと nginx 認証プロキシサイドカーを含む Container App を作成（既に存在する場合は更新）し、イングレスをポート 8080 の認証プロキシに向けます。
7. Container App が作成された時点で、公開エンドポイントの URL を表示します。これは後続の手順が成功するかどうかに関わらず行われます。
8. モデルのロードが完了するまで（Ollama コンテナの起動コマンド内で実行される `ollama pull` / `ollama run`）Container App をポーリングします。失敗またはタイムアウト時はエラーを表示して中断します。
9. モデルの準備完了が確認できたら、すぐに使える `curl` の実行例を表示し、エンドポイントURL・APIキー・モデル名・curl実行例を `result-endpoint.md` に書き出します（同梱の `chat.py` クライアントが参照します。下記の[利用方法](#利用方法)を参照）。

サポートされているリージョン / GPU の組み合わせ:

| リージョン | T4 | A100 |
|---|---|---|
| `westus3` | ✅ | ✅ |
| `swedencentral` | ✅ | ✅ |

これ以外のリージョン / GPU の組み合わせは、Azure リソースが作成される前に拒否されます。

`.\deploy.ps1` は再実行しても安全です。既存のリソース（リソースグループ、Environment、ワークロードプロファイル、Container App）は再作成されず、再利用または更新されます。

### モデルの変更

このデプロイはモデル非依存です。`.env` の `OLLAMA_MODEL` を [ollama.com/library](https://ollama.com/library) に存在する任意のモデルタグに変更して再デプロイすれば、起動コマンドが指定モデルに対して `ollama pull` / `ollama run` を実行します。認証プロキシ・API キー・`chat.py` はいずれもモデル名に依存せずそのまま動作します。

唯一の実質的な制約は GPU の VRAM です。T4 プロファイルは 16 GB、A100 プロファイルは 80 GB なので、`AZURE_GPU_TYPE` を適切に設定してください。おおよその収まり具合（Q4 量子化の概算）:

| モデル規模 | 必要VRAM目安 | T4 (16 GB) | A100 (80 GB) |
|---|---|:---:|:---:|
| 7B（例: `qwen2.5:7b`） | 約5 GB | ✅ | ✅ |
| 14B（`qwen2.5:14b`） | 約9 GB | ✅ | ✅ |
| `gpt-oss:20b`（既定） | 約13 GB | ✅（ぎりぎり） | ✅ |
| 30〜32B（`qwen3:30b`） | 約18〜22 GB | ❌ | ✅ |
| 70〜72B（`qwen2.5:72b`） | 約40〜45 GB | ❌ | ✅ |
| Kimi K2（1兆パラメータ MoE） | 数百 GB | ❌ | ❌（大きすぎて不可） |

指定できるモデル例: `gpt-oss:20b`（既定）, `qwen3:8b`, `qwen2.5:7b`, `qwen2.5:14b`, `qwen2.5-coder:7b`, `qwen3:30b`（A100向け）, `qwen2.5:72b`（A100向け）, `gemma3`, `llama3.1` など。

注: モデルを切り替えると、最初のリクエストでコールドスタート（新モデルの pull とロード）が発生するため、初回は時間がかかります。

## 利用方法

`deploy.ps1` は、公開エンドポイントのURL・APIキー・モデル名・（モデル準備完了時は）`curl` 実行例を、プロジェクトルートの `result-endpoint.md` に書き出します。このファイルは秘密情報（APIキー）を含むため、`.gitignore` によりバージョン管理から除外されています。

`curl` で直接エンドポイントを呼び出すこともできます。

```powershell
curl -X POST "$Url/api/generate" -H "X-API-Key: $ApiKey" -H "Content-Type: application/json" -d '{"model":"gpt-oss:20b","prompt":"Hello"}'
```

`$Url` は `deploy.ps1` が表示する公開エンドポイントに、`$ApiKey` は `.env` 内の `API_KEY` の値に置き換えてください。有効な `X-API-Key` ヘッダーを持たないリクエスト（欠落または不一致）は、認証プロキシサイドカーから `401` レスポンスを受け取り、Ollama へは転送されません。

### チャットクライアント（`chat.py`）

テキストのみの簡易的な対話を行うには、同梱の `chat.py` を使用します。このスクリプトは `result-endpoint.md` を読み込み、`/api/generate` エンドポイントと通信します。Python 3.8以上のみで動作し（標準ライブラリのみ使用、`pip install` は不要）：

```powershell
python chat.py
```

プロンプトを入力してEnterキーを押してください。終了するには `exit` または `quit` と入力するか、Ctrl+Cを押してください。主なオプション:

```powershell
python chat.py --file path\to\result-endpoint.md   # 別のresult-endpoint.mdファイルを指定する
python chat.py --no-stream                          # ストリーミングではなく、応答全文が完成してから表示する
python chat.py --timeout 180                        # HTTPタイムアウト秒数を延長する
```

注意: Container App はアイドル時にレプリカ数0にスケールダウンします（`minReplicas: 0`）。一定時間アクセスがない状態が続いた後の最初のリクエストは、コンテナの再起動とモデルの再ロードが発生するため、応答に時間がかかることがあります。

## 課金

このデプロイは、アイドル時にはほぼ課金が発生しないよう設計されています。

- **サーバーレス GPU・従量課金。** Container App は Consumption のサーバーレス GPU ワークロードプロファイル（例: `Consumption-GPU-NC8as-T4`）を使用します。課金対象はレプリカが実際に稼働している時間だけ（vCPU秒・メモリ(GiB)秒・GPU秒）で、秒単位で課金されます。サーバーレス GPU には「アイドル料金」という概念はありません。
- **アイドル時は0にスケール。** `minReplicas: 0` かつ既定の `cooldownPeriod`（300秒）で構成されています。公開イングレスへの最後のリクエストから約5分間アクセスがないと、レプリカが0へスケールダウンし、GPU/コンピュートの課金は完全に停止します。（`az containerapp show` などの管理系コマンドは「通信」に含まれず、クールダウンをリセットしません。）
- **コンテナ維持のためのストレージ課金はなし。** 永続ボリューム（Azure Files 等）は割り当てていません。コンテナイメージは公開 Docker レジストリから取得し（有料の Azure Container Registry は不使用）、`gpt-oss:20b` モデル（約13GB）は永続保存せず、コールドスタートのたびに一時（ephemeral）領域へ再ダウンロードします。そのため「コンテナを維持する」ためのストレージ課金は発生しません。トレードオフとして、0スケール後の初回リクエストは（再ダウンロードと再ロードのぶん）起動が遅くなります。
- **わずかに残る常時コスト。** Container Apps Environment に紐づく Log Analytics ワークスペースは、レプリカの稼働有無にかかわらずログのインジェスト/保持でごく少額の課金が発生し得ます。GPU コンピュートに比べれば微小です。

常時課金を完全にゼロにしたい場合は、`teardown.ps1` でリソースを削除してください（下記の[クリーンアップ](#クリーンアップ)を参照）。

詳細は [Azure Container Apps の課金](https://learn.microsoft.com/azure/container-apps/billing) および [サーバーレス GPU の利用](https://learn.microsoft.com/azure/container-apps/gpu-serverless-overview) を参照してください。

## プライベートエンドポイントによるプライベート運用（任意・上級）

既定では、このデプロイは API キーで保護された**パブリック**な HTTPS エンドポイントを公開します（[利用方法](#利用方法)を参照）。オンプレミスから **ExpressRoute** 経由で、または Azure VNet 内からアプリへ**プライベートに**到達したい場合は、Container Apps 環境を**プライベートエンドポイント**の背後に置けます。これはアプリのイングレスではなく **環境（Container Apps Environment）側**で設定するもので、**`deploy.ps1` では自動化していません**。

要点（最新の Azure ドキュメントで確認済み）:

- **カスタムドメインは必須ではありません。** アプリの既定 FQDN（`<app>.<region>.azurecontainerapps.io`）のまま利用でき、**プライベート DNS ゾーン**でその FQDN をプライベートエンドポイントのプライベート IP に解決させるだけです。カスタムドメインは自分のホスト名を使いたい場合のみ関係します（Apex/A レコードのカスタムドメインではプライベートエンドポイントの IP を指す。CNAME のカスタムドメインは変更不要）。
- プライベートエンドポイントは **ワークロードプロファイル環境**（本プロジェクトが作成する環境タイプ）でサポートされ、**環境の VNet 統合を必要としません**。
- アプリのイングレスは **external（どこからでも）のまま**でよく、**環境レベルでパブリックネットワークアクセスを無効化**することでプライベート化されます。
- **内部（VNet/ILB）環境**は環境作成時にしか選択できません。この既存の外部環境では、作り直さずにプライベート化する手段が**プライベートエンドポイント方式**になります。

設定場所（Azure ポータル）:

1. **Container Apps 環境**（`cae-ollama-gptoss20b`）→ **ネットワーク** を開く。
2. **パブリックネットワークアクセス**を**無効にする**。すると **プライベートエンドポイント**セクションが表示されます。（プライベートエンドポイントを構成すると、以後パブリックアクセスは再有効化できません＝排他です。）
3. **プライベートエンドポイント**から追加する:
   - 自分の **VNet ＋ サブネット**に配置する（サブネットは **/27 以上**）。
   - **プライベート DNS ゾーン**統合を有効にし、既定 FQDN がプライベート IP に解決されるようにする。

実際に利用するための前提:

- プライベートエンドポイントを配置する Azure の **VNet ＋ サブネット（/27 以上）**。
- オンプレミスから使う場合: **ExpressRoute** 回線 ＋ **プライベートピアリング**、その VNet への接続、およびオンプレミス側の DNS がプライベート DNS ゾーンを解決できる構成（DNS フォワーダ等）。

注意点:

- パブリックネットワークアクセスを無効化すると**インターネットからの到達が遮断**され、上記のパブリックな `curl` / `chat.py` の例は VNet 内または ExpressRoute 経由以外からは届かなくなります。VNet・プライベートエンドポイント・DNS・接続経路を**整えてから**無効化してください。先に無効化すると自分も締め出されます。
- API キー認証プロキシはいずれの場合も残るため、多層防御になります。

詳細は [Azure Container Apps 環境でのプライベートエンドポイントの使用](https://learn.microsoft.com/ja-jp/azure/container-apps/how-to-use-private-endpoint) および [仮想ネットワークのプライベートエンドポイントと DNS の構成](https://learn.microsoft.com/ja-jp/azure/container-apps/private-endpoints-with-dns) を参照してください。

## クリーンアップ

`deploy.ps1` が作成したリソースを削除するには、以下を実行します。

```powershell
.\teardown.ps1
```

既定では、`.env` の `AZURE_RESOURCE_GROUP` で指定されたリソースグループを削除する前に、確認プロンプト（`y`/`N`）が表示されます。確認プロンプトをスキップするには:

```powershell
.\teardown.ps1 -Force
```

このスクリプトはリソースグループ全体を削除します（`az group delete --yes --no-wait`）。これにより、Container Apps Environment と Container App も一緒に削除されます。削除は非同期で実行され（`--no-wait`）、実際の削除完了は Azure 側でバックグラウンドで行われます。削除に失敗した場合（権限エラーや API エラーなど）、スクリプトは再試行せずに失敗内容を報告して終了します。
