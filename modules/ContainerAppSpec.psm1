<#
.SYNOPSIS
    `.env`設定値から `az containerapp create/update --yaml` に渡すYAML文字列を生成する純粋関数群。

.DESCRIPTION
    Requirements: 3.1, 3.2, 3.3, 4.1, 4.3
    - New-ContainerAppYaml: Ollama_Container（先頭定義、`docker.io/ollama/ollama:latest`）と
      Auth_Proxy_Container（`nginx:alpine`）の2コンテナ、`external: true`かつ`targetPort: 8080`の
      イングレス、GPUマッピングによる`workloadProfileName`を含むYAML文字列を生成する。
      Ollama_Containerの起動コマンドには`OllamaStartup.psm1`（`New-OllamaStartupScript`）の出力、
      Auth_Proxy_Containerの起動コマンドには`NginxConfig.psm1`（`New-NginxConfigScript`）の出力を、
      それぞれYAMLリテラルブロックスカラ（`|-`）として埋め込む。

    Container Apps の仕様上、同一Container App内で最初に定義されたコンテナがGPUへのアクセス権を
    得るため、`properties.template.containers`配列ではOllama_Containerを先頭（インデックス0）に
    定義する。
#>

Set-StrictMode -Version Latest

# 依存モジュール（New-OllamaStartupScript, New-NginxConfigScript, Get-WorkloadProfile）を
# $PSScriptRoot基準の相対パスでインポートし、このモジュール単体で self-contained に利用できるようにする
Import-Module (Join-Path $PSScriptRoot 'OllamaStartup.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'NginxConfig.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GpuProfile.psm1') -Force

# Auth_Proxy_Containerに割り当てる固定のリソース量（残りをOllama_Containerに割り当てる）
$script:AuthProxyCpu = 0.5
$script:AuthProxyMemoryGiB = 1

function ConvertTo-YamlDoubleQuotedScalar {
    <#
    .SYNOPSIS
        単純な文字列値をYAMLの二重引用符付きスカラーとして安全に埋め込めるようエスケープする
        （内部ヘルパー、非公開）。
    .DESCRIPTION
        値中の `\` と `"` をバックスラッシュエスケープする。改行を含まない短い値
        （コンテナ名・イメージ名・モデル名・APIキー・プロファイル名等）にのみ使用する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function ConvertTo-YamlLiteralBlockScalar {
    <#
    .SYNOPSIS
        複数行になり得る文字列（シェル起動スクリプト等）をYAMLリテラルブロックスカラー
        （`|-`）として、指定したインデント幅で埋め込めるよう整形する（内部ヘルパー、非公開）。
    .DESCRIPTION
        リテラルブロックスカラーを使うことで、値中の引用符（`'`/`"`）やドル記号を
        YAML側でエスケープする必要がなくなり、シェルスクリプト文字列を安全かつそのままの
        内容で埋め込める。`|-`（strip chomping）を用いることで、元の文字列に含まれない
        余分な末尾改行がYAML側で付与されることを防ぐ。
    .PARAMETER Value
        埋め込む文字列（`\r\n`または`\n`改行を含み得る）。
    .PARAMETER IndentSpaces
        ブロックスカラー本文の各行に付与するインデント（半角スペース数）。
    .OUTPUTS
        string : `|-` インジケーター行を含む、呼び出し側でそのまま貼り付け可能な複数行文字列
        （ただし1行目の `|-` 自体にはインデントを含まない。呼び出し側が配置する行頭位置に応じて
        呼び出し元が `|-` の前にインデントを付与すること）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [int]$IndentSpaces
    )

    $indent = ' ' * $IndentSpaces
    $lines = $Value -split "`r`n|`n"
    $indentedLines = $lines | ForEach-Object { "$indent$_" }
    return "|-`n" + ($indentedLines -join "`n")
}

function Get-ContainerResourceAllocation {
    <#
    .SYNOPSIS
        ワークロードプロファイルの上限リソースを、Ollama_ContainerとAuth_Proxy_Containerに
        分配する（内部ヘルパー、非公開・純粋関数）。
    .DESCRIPTION
        Auth_Proxy_Containerには固定の少量（0.5 vCPU / 1 GiB）を割り当て、残りをGPUアクセス権を
        持つOllama_Containerに割り当てる。ワークロードプロファイルの上限値は常にこの固定量より
        大きいため、Ollama_Container側の割り当ては常に正の値になる。
    .PARAMETER WorkloadProfile
        `Get-WorkloadProfile`が返す `@{MaxCpu; MaxMemoryGiB; ...}` 形式のhashtable。
    .OUTPUTS
        hashtable (@{OllamaCpu; OllamaMemoryGiB; AuthProxyCpu; AuthProxyMemoryGiB})
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$WorkloadProfile
    )

    return @{
        OllamaCpu          = $WorkloadProfile.MaxCpu - $script:AuthProxyCpu
        OllamaMemoryGiB    = $WorkloadProfile.MaxMemoryGiB - $script:AuthProxyMemoryGiB
        AuthProxyCpu       = $script:AuthProxyCpu
        AuthProxyMemoryGiB = $script:AuthProxyMemoryGiB
    }
}

function New-ContainerAppSpec {
    <#
    .SYNOPSIS
        `.env`設定値から、Azure ARM REST API（`az rest`経由）に渡すContainer Appリソース定義を
        PowerShellのネスト済みhashtableとして生成する。
    .DESCRIPTION
        Requirements: 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3
        `New-ContainerAppYaml`と同一の構成内容（Ollama_Container先頭定義、Auth_Proxy_Container、
        イングレス、ワークロードプロファイル等）を、YAML文字列ではなくPowerShellの
        hashtable/配列としてそのまま返す。呼び出し元は`ConvertTo-Json -Depth <十分な深さ>`で
        JSON化し、`az rest --method PUT`等でARM APIへ直接送信することを想定する。

        注: 実機のAzure環境での検証により、`az containerapp create/update --yaml`コマンド自体の
        内部YAML→JSON変換処理に不具合があり、`az`にとって正しい構造のYAMLを渡しても
        "Bad Request: The JSON value could not be converted to System.Boolean" エラーで
        失敗することが判明した（`az`バージョン2.87.0で確認、`az rest`で同一内容のJSONを
        直接送信すると成功することを確認済み）。この関数はその回避策として、
        YAML経由ではなくJSON（hashtable）を直接組み立てるために追加した。

        各コンテナは`command: ["sh", "-c"]` / `args: [<スクリプト本体>]`という構成である
        （`New-OllamaStartupScript`/`New-NginxConfigScript`はスクリプト本体のみを返し、
        `sh -c`ラッパーは付与しない）。以前は`args`側の文字列自体に`sh -c '...'`という
        ラッパーが含まれていたため、`command`の`sh -c`と合わせて`sh -c`が二重にネストされる
        不具合があり、Auth_Proxy_Container/Ollama_Containerが起動時にクラッシュループすることが
        実機のAzure環境での検証により判明したため、この構成に修正した。

        この関数は純粋関数である：同一の`$Config`に対して常に同一のhashtableを返す。
    .PARAMETER Config
        `New-ContainerAppYaml`と同じキー要件（`ModelName`/`GpuType`/`ApiKey`/`ContainerAppName`/
        `EnvironmentId`、いずれも必須）。
    .PARAMETER Location
        Container Appを作成するAzureリージョン（ARM APIのリクエストボディ直下の`location`に
        必要。`.env`の`AZURE_LOCATION`）。
    .OUTPUTS
        hashtable : `ConvertTo-Json`でARM REST APIのリクエストボディに変換できるネスト済みhashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    foreach ($requiredKey in @('ModelName', 'GpuType', 'ApiKey', 'ContainerAppName', 'EnvironmentId')) {
        if (-not $Config.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace([string]$Config[$requiredKey])) {
            throw "Config is missing required key: $requiredKey"
        }
    }

    $workloadProfile = Get-WorkloadProfile -GpuType $Config.GpuType
    $resourceAllocation = Get-ContainerResourceAllocation -WorkloadProfile $workloadProfile

    $ollamaStartupScript = New-OllamaStartupScript -ModelName $Config.ModelName
    $nginxConfigScript = New-NginxConfigScript -ApiKey $Config.ApiKey

    return @{
        location   = $Location
        properties = @{
            environmentId      = $Config.EnvironmentId
            workloadProfileName = $workloadProfile.FriendlyName
            configuration      = @{
                ingress   = @{
                    external   = $true
                    targetPort = 8080
                    transport  = 'Auto'
                }
                secrets   = @(
                    @{
                        name  = 'api-key'
                        value = $Config.ApiKey
                    }
                )
            }
            template           = @{
                containers = @(
                    @{
                        name      = 'ollama'
                        image     = 'docker.io/ollama/ollama:latest'
                        command   = @('sh', '-c')
                        args      = @($ollamaStartupScript)
                        env       = @(
                            @{
                                name  = 'OLLAMA_MODEL'
                                value = $Config.ModelName
                            }
                        )
                        resources = @{
                            cpu    = $resourceAllocation.OllamaCpu
                            memory = "$($resourceAllocation.OllamaMemoryGiB)Gi"
                        }
                    },
                    @{
                        name      = 'auth-proxy'
                        image     = 'nginx:alpine'
                        command   = @('sh', '-c')
                        args      = @($nginxConfigScript)
                        env       = @(
                            @{
                                name      = 'API_KEY'
                                secretRef = 'api-key'
                            }
                        )
                        resources = @{
                            cpu    = $resourceAllocation.AuthProxyCpu
                            memory = "$($resourceAllocation.AuthProxyMemoryGiB)Gi"
                        }
                    }
                )
                scale      = @{
                    minReplicas = 0
                    maxReplicas = 1
                }
            }
        }
    }
}

function New-ContainerAppYaml {
    <#
    .SYNOPSIS
        `.env`設定値から `az containerapp create/update --yaml` に渡すYAML文字列を生成する。
    .DESCRIPTION
        生成されるYAMLは以下を必ず含む（design.md「Container App リソースモデル」参照）:
        - `properties.template.containers[0]`: Ollama_Container
          （`name: ollama`, `image: docker.io/ollama/ollama:latest`、
          `command: ["sh", "-c"]` / `args`に`New-OllamaStartupScript`の出力、
          環境変数 `OLLAMA_MODEL`、resources）
        - `properties.template.containers[1]`: Auth_Proxy_Container
          （`name: auth-proxy`, `image: nginx:alpine`、
          `command: ["sh", "-c"]` / `args`に`New-NginxConfigScript`の出力、
          環境変数 `API_KEY`（secretRef: api-key）、resources）
        - `properties.configuration.ingress`: `external: true`, `targetPort: 8080`, `transport: auto`
        - `properties.configuration.secrets`: `api-key` シークレット（値は`Config.ApiKey`）
        - `properties.environmentId`: `Config.EnvironmentId`（Container_Apps_EnvironmentのリソースID）
        - `properties.workloadProfileName`: `Get-WorkloadProfile`のFriendlyName
          （`Config.GpuType`に基づく）
        - `properties.template.scale`: `minReplicas: 0`, `maxReplicas: 1`
        Container Apps の仕様上、GPUへのアクセス権は最初に定義されたコンテナに付与されるため、
        Ollama_Containerを常にコンテナ配列の先頭（インデックス0）に定義する。

        起動コマンド文字列（シェルスクリプト）は、引用符やドル記号のエスケープを避けるため
        YAMLリテラルブロックスカラー（`|-`）として埋め込む。`New-OllamaStartupScript`/
        `New-NginxConfigScript`はスクリプト本体のみを返す（`sh -c`ラッパーは付与しない）ため、
        `command: ["sh", "-c"]` + `args: [<スクリプト本体>]`という構成で正しく1回だけ
        `sh -c`が適用される（以前はこれらの関数自体が`sh -c '...'`を含む文字列を返していたため
        `sh -c`が二重にネストされ、コンテナがクラッシュループする不具合があったため修正した）。

        注: `properties.environmentId`は、実機のAzure環境での検証により
        `az containerapp create --yaml`実行時に必須であることが判明した
        （未指定の場合 "environmentId is required" エラーとなる）。design.mdの初版YAML例には
        この項目が記載されていなかったため、本実装で追加した。プロパティ名は
        `managedEnvironmentId`ではなく`environmentId`が正しい
        （Microsoft Learn「Azure Container Apps ARM and YAML template specifications」参照）。

        この関数は純粋関数である：同一の`$Config`に対して常に同一のYAML文字列を返す
        （依存する`New-OllamaStartupScript`/`New-NginxConfigScript`/`Get-WorkloadProfile`も
        いずれも純粋関数のため）。
    .PARAMETER Config
        以下のキーを含むhashtable（`.env`のキー名とは異なる、本関数用の命名規則）:
        - `ModelName` [string] (必須): pull/run対象のOllamaモデル名（`.env`の`OLLAMA_MODEL`）
        - `GpuType` [string] (必須): GPU種別 `"T4"` または `"A100"`（`.env`の`AZURE_GPU_TYPE`）
        - `ApiKey` [string] (必須): Auth_Proxy_Containerが検証に用いるAPIキー（`.env`の`API_KEY`）
        - `ContainerAppName` [string] (必須): 生成するYAML内の`name`フィールドに使用する
          Container App名（`.env`の`AZURE_CONTAINER_APP_NAME`）
        - `EnvironmentId` [string] (必須): 対象のContainer_Apps_EnvironmentのAzureリソースID
          （`az containerapp env show --query id -o tsv`等で取得する完全なARM リソースID）
    .OUTPUTS
        string : `az containerapp create/update --yaml` に渡せるYAML文字列
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )

    foreach ($requiredKey in @('ModelName', 'GpuType', 'ApiKey', 'ContainerAppName', 'EnvironmentId')) {
        if (-not $Config.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace([string]$Config[$requiredKey])) {
            throw "Config is missing required key: $requiredKey"
        }
    }

    $workloadProfile = Get-WorkloadProfile -GpuType $Config.GpuType
    $resourceAllocation = Get-ContainerResourceAllocation -WorkloadProfile $workloadProfile

    $ollamaStartupScript = New-OllamaStartupScript -ModelName $Config.ModelName
    $nginxConfigScript = New-NginxConfigScript -ApiKey $Config.ApiKey

    # args配下のリテラルブロックスカラー本文のインデント（"          - |-" の "-" が10桁目のため、
    # 本文は"-"より深い12桁インデントとする）
    $ollamaArgsBlock = ConvertTo-YamlLiteralBlockScalar -Value $ollamaStartupScript -IndentSpaces 12
    $nginxArgsBlock = ConvertTo-YamlLiteralBlockScalar -Value $nginxConfigScript -IndentSpaces 12

    $containerAppNameYaml = ConvertTo-YamlDoubleQuotedScalar -Value $Config.ContainerAppName
    $workloadProfileNameYaml = ConvertTo-YamlDoubleQuotedScalar -Value $workloadProfile.FriendlyName
    $apiKeyYaml = ConvertTo-YamlDoubleQuotedScalar -Value $Config.ApiKey
    $modelNameYaml = ConvertTo-YamlDoubleQuotedScalar -Value $Config.ModelName
    $environmentIdYaml = ConvertTo-YamlDoubleQuotedScalar -Value $Config.EnvironmentId

    $yaml = @"
name: $containerAppNameYaml
properties:
  environmentId: $environmentIdYaml
  workloadProfileName: $workloadProfileNameYaml
  configuration:
    ingress:
      external: true
      targetPort: 8080
      transport: auto
    secrets:
      - name: api-key
        value: $apiKeyYaml
  template:
    containers:
      - name: ollama
        image: "docker.io/ollama/ollama:latest"
        command: ["sh", "-c"]
        args:
          - $ollamaArgsBlock
        env:
          - name: OLLAMA_MODEL
            value: $modelNameYaml
        resources:
          cpu: $($resourceAllocation.OllamaCpu)
          memory: "$($resourceAllocation.OllamaMemoryGiB)Gi"
      - name: auth-proxy
        image: "nginx:alpine"
        command: ["sh", "-c"]
        args:
          - $nginxArgsBlock
        env:
          - name: API_KEY
            secretRef: api-key
        resources:
          cpu: $($resourceAllocation.AuthProxyCpu)
          memory: "$($resourceAllocation.AuthProxyMemoryGiB)Gi"
    scale:
      minReplicas: 0
      maxReplicas: 1
"@

    return $yaml
}

Export-ModuleMember -Function New-ContainerAppYaml, New-ContainerAppSpec
