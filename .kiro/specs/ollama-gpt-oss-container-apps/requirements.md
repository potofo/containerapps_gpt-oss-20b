# Requirements Document

## Introduction

このプロジェクトは、Azure Container Apps のサーバーレス GPU 機能を利用し、Ollama コンテナー上で OpenAI の gpt-oss-20b モデルを実行するエンドポイントを、Azure CLI によって完全自動でプロビジョニングする仕組みを提供する。利用者は `.env` ファイルにサブスクリプションID・リージョン・GPU種別・APIキー等の設定値を記述し、1本のデプロイスクリプトを実行するだけで、リソースグループ作成からモデルのロード、APIキー認証付きインターネット公開までを完了できる。

Ollama自体にはAPIキー認証機能がないため、Container App内にサイドカーコンテナとして認証プロキシ（公開のnginx公式イメージ + 起動コマンドによる設定ファイル注入）を配置し、リクエストヘッダーのAPIキーを検証してからOllamaコンテナへ転送する構成とする。

## Glossary

- **Deployment_Script**: 利用者が実行する、Azureリソースのプロビジョニングからモデルのロードまでを自動化するAzure CLIベースのスクリプト群。
- **Environment_Configuration_File**: 利用者が設定値を記述する `.env` ファイル、およびそのテンプレートである `.env.example` ファイル。
- **Resource_Group**: デプロイ対象のAzureリソースをまとめて格納するAzureリソースグループ。
- **Container_Apps_Environment**: GPUワークロードプロファイルを持つAzure Container Apps環境。
- **Container_App**: Ollama_ContainerとAuth_Proxy_Containerを含むAzure Container Appsのアプリケーションリソース。
- **Ollama_Container**: `ollama/ollama:latest` イメージを使用し、ポート11434でリクエストを受け付けるメインコンテナ。
- **Auth_Proxy_Container**: Container_App内に配置される、公開のnginx公式イメージを起動コマンドでカスタマイズしたサイドカーコンテナ。リクエストヘッダーのAPI_Keyを検証し、有効な場合のみOllama_Containerへリクエストを転送する。
- **GPT_OSS_Model**: Ollama_Container上でロード・実行される `gpt-oss:20b` モデル。
- **API_Key**: Container_Appのエンドポイントへのアクセスを許可するために必要な、リクエストヘッダーで送信される秘密文字列。
- **GPU_Type**: Container_Appに割り当てるGPUの種類。`T4` または `A100` のいずれか。
- **Deployment_Region**: Container_Apps_Environmentをデプロイするリージョン。`westus3`（米国西部3）または `swedencentral`（スウェーデン中部）のいずれか。
- **Public_Endpoint**: Container_Appのイングレスにより公開される、インターネットからアクセス可能なURL。
- **Teardown_Script**: Deployment_Scriptによって作成されたAzureリソースを削除するAzure CLIベースのスクリプト。
- **Project_Documentation**: 利用者向けに事前準備・使い方を説明する `README.md`（英語）および `README.ja-JP.md`（日本語）のドキュメントファイル一式。

## Requirements

### Requirement 1: 環境設定ファイルによる構成管理

**User Story:** As a 利用者, I want デプロイに必要な設定値を`.env`ファイルで管理したい, so that ポータル操作なしでスクリプトに設定値を渡し、繰り返し利用・共有できる。

#### Acceptance Criteria

1. THE Deployment_Script SHALL Environment_Configuration_Fileから、サブスクリプションID、テナントID、Resource_Group名、Deployment_Region、Container_App名、Container_Apps_Environment名、GPU_Type、Ollamaモデル名、API_Keyの設定値を読み込む。
2. THE リポジトリ SHALL 各設定項目に説明コメントと設定例を記載した `.env.example` ファイルを含む。
3. WHEN 利用者が `.env.example` を `.env` にコピーして値を編集するとき, THE Deployment_Script SHALL 追加のコード変更なしにデプロイを実行できる。
4. IF Environment_Configuration_Fileに必須項目（API_Keyを除く）が未設定であるとき, THEN THE Deployment_Script SHALL 該当する項目名を含むエラーメッセージを表示して処理を中断する。設定値の形式チェックや到達可能性チェックは行わない。
5. IF Environment_Configuration_FileのAPI_Keyが未設定であるとき, THEN THE Deployment_Script SHALL ランダムなAPI_Keyを自動生成し、生成した値をEnvironment_Configuration_Fileに書き込み、デプロイ処理を継続する。

### Requirement 2: リソースグループとContainer Apps環境の自動作成

**User Story:** As a 利用者, I want リソースグループとGPU対応のContainer Apps環境をコマンド一つで作成したい, so that Azureポータルを操作せずに済む。

#### Acceptance Criteria

1. WHEN Deployment_Scriptが実行されるとき, THE Deployment_Script SHALL Environment_Configuration_Fileで指定されたResource_Group名とDeployment_Regionを使用してResource_Groupを作成する。
2. IF 指定された名前のResource_Groupが既に存在するとき, THEN THE Deployment_Script SHALL 既存のResource_Groupを再作成せずに再利用する。
3. WHEN Resource_Groupの準備が完了したとき, THE Deployment_Script SHALL GPUワークロードプロファイルを持つConsumptionプランのContainer_Apps_EnvironmentをDeployment_Region内に作成する。
4. IF 指定されたDeployment_RegionとGPU_Typeの組み合わせがサポート対象外であるとき, THEN THE Deployment_Script SHALL 対応可能なリージョンとGPU種別の一覧を含むエラーメッセージを表示して処理を中断する。
5. THE Deployment_Script SHALL `westus3`と`swedencentral`の両リージョンについて、`T4`と`A100`のGPU_Typeを有効な組み合わせとして受け付ける。この組み合わせ検証はDeployment_Scriptの仕様上の許可判定であり、実際のAzure側のクォータやキャパシティ状況を事前確認するものではない。検証に合格した場合でも、Deployment_Scriptは後続の処理内容やAzure側のエラーにより処理を中断することがある。

### Requirement 3: Ollamaコンテナーアプリの自動デプロイ

**User Story:** As a 利用者, I want Ollamaコンテナーを含むContainer AppをGPU割り当て・イングレス設定込みで自動デプロイしたい, so that 手動でのコンテナー設定作業が不要になる。

#### Acceptance Criteria

1. WHEN Container_Apps_Environmentの準備が完了したとき, THE Deployment_Script SHALL `docker.io/ollama/ollama:latest` イメージを使用するOllama_ContainerをContainer_App内に作成する。
2. THE Deployment_Script SHALL Container_AppにEnvironment_Configuration_Fileで指定されたGPU_Typeを割り当てる。このGPU割り当て処理は、Container_App本体の作成が完了しているかどうかに関わらず実行される。
3. THE Deployment_Script SHALL Container_Appのイングレスを有効にし、外部トラフィックを許可し、ターゲットポートを11434に設定する。
4. WHILE Container_Appへのリクエストが存在しない状態が続くとき, THE Container_Apps_Environment SHALL Container_Appのレプリカ数を0にスケールする。
5. WHEN Container_Appの作成が完了したとき, THE Deployment_Script SHALL GPU割り当てや他の後続セットアップ手順の成否に関わらず、Public_EndpointのURLをコンソール出力に表示する。

### Requirement 4: APIキー認証プロキシの自動構成

**User Story:** As a 利用者, I want APIキーを知らない第三者がエンドポイントを呼び出せないようにしたい, so that Ollamaのモデル呼び出しを安全に公開できる。

#### Acceptance Criteria

1. THE Deployment_Script SHALL 公開のnginx公式イメージを使用するAuth_Proxy_ContainerをContainer_App内にサイドカーとして追加する。
2. THE Deployment_Script SHALL Auth_Proxy_Containerの起動コマンドを介して、API_Keyの検証ロジックを含むnginx設定をコンテナ起動時に注入する。
3. THE Deployment_Script SHALL Container_Appのイングレスのターゲットポートを、Ollama_Containerの11434ポートではなくAuth_Proxy_Containerが待ち受けるポートに設定する。
4. IF Public_EndpointへのリクエストにAPI_Keyヘッダーが含まれていないとき, THEN THE Auth_Proxy_Container SHALL API_Keyの一致判定を行わずにリクエストを拒否し、401エラーを応答する。
5. WHEN Public_Endpointへのリクエストのヘッダーに、設定済みのAPI_Keyと一致する値が含まれているとき, THE Auth_Proxy_Container SHALL レート制限やメンテナンスモードなど他の状態に関わらず、常にリクエストをOllama_Containerへ転送する。
6. IF Public_EndpointへのリクエストにAPI_Keyヘッダーが含まれており、その値が設定済みのAPI_Keyと一致しないとき, THEN THE Auth_Proxy_Container SHALL リクエストを拒否し、401エラーを応答する。

### Requirement 5: gpt-oss-20bモデルのロードと実行

**User Story:** As a 利用者, I want gpt-oss:20bモデルの取得と起動を自動化したい, so that デプロイ後すぐにモデルを呼び出せる。

#### Acceptance Criteria

1. WHEN Container_Appのデプロイが完了したとき, THE Deployment_Script SHALL Ollama_Container内で `ollama pull gpt-oss:20b` を実行する。
2. WHEN GPT_OSS_Modelの取得が完了したとき, THE Deployment_Script SHALL ネットワーク接続やコンテナ準備状態などの追加条件を待たずに、直ちにOllama_Container内で `ollama run gpt-oss:20b` を実行し、モデルをロード状態にする。
3. IF GPT_OSS_Modelの取得が失敗するとき, THEN THE Deployment_Script SHALL エラー内容を含むメッセージを表示して処理を中断する。
4. THE Deployment_Script SHALL Environment_Configuration_Fileで指定されたOllamaモデル名を、`ollama pull`および`ollama run`コマンドの対象モデルとして使用する。

### Requirement 6: エンドツーエンドのAPI呼び出し確認

**User Story:** As a 利用者, I want デプロイ完了後に有効なAPIキーでgpt-oss-20bのエンドポイントを呼び出せることを確認したい, so that デプロイが正しく完了したことを検証できる。

#### Acceptance Criteria

1. WHEN Deployment_Scriptの全工程が完了したとき, THE Public_Endpoint SHALL 有効なAPI_Keyを付与した `/api/generate` へのHTTPリクエストに対して、GPT_OSS_Modelが生成した応答を返す。
2. WHEN Deployment_Scriptの全工程が完了したとき, THE Deployment_Script SHALL Public_EndpointのURLと有効なAPI_Keyを用いたcurlコマンドの実行例をコンソール出力に表示する。デプロイが完了する前にはこの実行例を表示しない。

### Requirement 7: デプロイスクリプトの再実行可能性とエラーハンドリング

**User Story:** As a 利用者, I want デプロイスクリプトを安全に再実行したい, so that 途中で失敗した場合でも同じスクリプトで復旧できる。

#### Acceptance Criteria

1. IF 指定された名前のContainer_Apps_Environmentが既に存在するとき, THEN THE Deployment_Script SHALL 既存のContainer_Apps_Environmentを再作成せずに再利用する。
2. IF 指定された名前のContainer_Appが既に存在するとき, THEN THE Deployment_Script SHALL 既存のContainer_Appの設定を更新し、この更新処理が失敗した場合でも残りのデプロイ手順の実行を継続する。
3. IF Azure CLIへのログインセッションが存在しないとき, THEN THE Deployment_Script SHALL ログインが必要であることを示すエラーメッセージを表示して処理を中断する。
4. IF Environment_Configuration_Fileで指定されたサブスクリプションIDが現在のAzure CLIコンテキストと異なるとき, THEN THE Deployment_Script SHALL 利用者への確認を求めずに、指定されたサブスクリプションIDへコンテキストを自動的に切り替える。

### Requirement 8: リソースのクリーンアップ

**User Story:** As a 利用者, I want 検証終了後に作成したリソースをまとめて削除したい, so that 不要なAzure利用料金の発生を防げる。

#### Acceptance Criteria

1. WHEN 利用者がTeardown_Scriptを実行するとき, THE Teardown_Script SHALL Environment_Configuration_Fileで指定されたResource_Groupを削除する。
2. IF Resource_Groupの削除がAzureの権限エラーまたはAPIエラーにより失敗するとき, THEN THE Teardown_Script SHALL 削除を再試行せずに失敗内容を報告して処理を終了する。
3. WHERE 利用者がTeardown_Scriptの実行時に削除確認オプションを指定しないとき, THE Teardown_Script SHALL 削除を実行する前に確認入力を要求する。

### Requirement 9: ドキュメントによる事前準備の案内

**User Story:** As a 利用者, I want Deployment_Scriptを実行する前に必要な事前準備を把握したい, so that `az login`未実施によるエラーで手順を中断せずに済む。

#### Acceptance Criteria

1. THE リポジトリ SHALL 英語版の `README.md` と日本語版の `README.ja-JP.md` からなるProject_Documentationを含む。
2. THE Project_Documentation SHALL Deployment_Scriptの実行前に利用者自身が対話型の `az login` を一度実行し、Azureへの認証済みセッションを確立しておく必要があることを、事前準備の項目として明記する。
3. THE Project_Documentation SHALL Deployment_ScriptがAzureへの認証処理（`az login`の実行）を代行しないこと、および認証済みセッションが存在しない場合はDeployment_Scriptがエラーを表示して中断することを明記する。
4. THE Project_Documentation SHALL `.env.example` を `.env` にコピーして設定値を編集する手順を、Deployment_Script実行前の事前準備の一部として説明する。
5. THE README.mdとREADME.ja-JP.md SHALL 事前準備・利用手順・クリーンアップ手順について同一の内容を、それぞれの言語で記載する。
