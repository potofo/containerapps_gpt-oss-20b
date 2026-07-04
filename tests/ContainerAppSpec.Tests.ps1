<#
.SYNOPSIS
    ContainerAppSpec.psm1 の具体例・エッジケースを検証する単体テスト（Pester）。

.DESCRIPTION
    Requirements: 3.1, 3.2, 3.3, 4.1, 4.3
    - New-ContainerAppYaml: 生成されたYAML文字列がYAMLパーサーで正しくパースできることを検証する
      （構文妥当性の単体テスト）。基本的な構造の健全性チェックも合わせて行うが、
      網羅的なプロパティ検証はProperty 6（Property-basedテスト）の役割とする。
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\ContainerAppSpec.psm1'
Import-Module $modulePath -Force

# このテストファイル用のYAML構文検証ヘルパー（内部専用）。
# PowerShellには標準のYAMLパーサーが無いため、実行環境に存在するPython + PyYAMLへ
# シェルアウトしてYAML文字列をパースし、JSON文字列として標準出力から受け取ることで
# PowerShell側の ConvertFrom-Json を用いて構造検証できるようにする。
function ConvertFrom-YamlViaPython {
    <#
    .SYNOPSIS
        YAML文字列をPython(PyYAML)経由でパースし、PSCustomObjectとして返す（テスト専用ヘルパー）。
    .DESCRIPTION
        パースに失敗した場合（YAML構文エラー等）は例外をスローする。
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlContent
    )

    $tempYamlPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString() + '.yaml')
    # az CLIに渡すYAML文字列はUTF-8として扱われるため、テストでもUTF-8（BOM無し）で書き込む
    [System.IO.File]::WriteAllText($tempYamlPath, $YamlContent, [System.Text.UTF8Encoding]::new($false))

    $pythonScript = @'
import json
import sys
import yaml

with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()

data = yaml.safe_load(content)
print(json.dumps(data))
'@

    $tempScriptPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString() + '.py')
    [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, [System.Text.UTF8Encoding]::new($false))

    $jsonOutput = & python $tempScriptPath $tempYamlPath 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "YAML parse failed (python exit code $exitCode): $jsonOutput"
    }

    return ($jsonOutput | Out-String) | ConvertFrom-Json
}

Describe 'ContainerAppSpec.psm1' {

    Context 'New-ContainerAppYaml - YAML構文妥当性（単体テスト）' {

        It 'T4 GPU設定の生成YAMLがYAMLパーサーで正しくパースでき、期待される構造を持つ' {
            $config = @{
                ModelName        = 'gpt-oss:20b'
                GpuType          = 'T4'
                ApiKey           = 'simpleApiKey123'
                ContainerAppName = 'ca-ollama-gptoss20b'
                EnvironmentId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test'
            }

            $yaml = New-ContainerAppYaml -Config $config

            $parsed = ConvertFrom-YamlViaPython -YamlContent $yaml

            $parsed.name | Should Be 'ca-ollama-gptoss20b'
            $parsed.properties.workloadProfileName | Should Be 'Consumption-GPU-NC8as-T4'

            $containers = $parsed.properties.template.containers
            $containers.Count | Should Be 2
            $containers[0].name | Should Be 'ollama'
            $containers[0].image | Should Be 'docker.io/ollama/ollama:latest'
            $containers[1].name | Should Be 'auth-proxy'
            $containers[1].image | Should Be 'nginx:alpine'

            $parsed.properties.configuration.ingress.external | Should Be $true
            $parsed.properties.configuration.ingress.targetPort | Should Be 8080
        }

        It 'A100 GPU設定の生成YAMLがYAMLパーサーで正しくパースでき、期待される構造を持つ' {
            $config = @{
                ModelName        = 'gpt-oss:20b'
                GpuType          = 'A100'
                ApiKey           = 'anotherApiKey456'
                ContainerAppName = 'ca-ollama-a100'
                EnvironmentId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test'
            }

            $yaml = New-ContainerAppYaml -Config $config

            $parsed = ConvertFrom-YamlViaPython -YamlContent $yaml

            $parsed.name | Should Be 'ca-ollama-a100'
            $parsed.properties.workloadProfileName | Should Be 'Consumption-GPU-NC24-A100'

            $containers = $parsed.properties.template.containers
            $containers.Count | Should Be 2
            $containers[0].name | Should Be 'ollama'
            $containers[1].name | Should Be 'auth-proxy'

            $parsed.properties.template.scale.minReplicas | Should Be 0
            $parsed.properties.template.scale.maxReplicas | Should Be 1
        }

        It 'APIキーに二重引用符・バックスラッシュを含む場合でもYAMLパーサーで正しくパースできる' {
            $config = @{
                ModelName        = 'gpt-oss:20b'
                GpuType          = 'T4'
                ApiKey           = 'key"with\backslash"and"quotes'
                ContainerAppName = 'ca-ollama-special'
                EnvironmentId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test'
            }

            $yaml = New-ContainerAppYaml -Config $config

            $parsed = ConvertFrom-YamlViaPython -YamlContent $yaml

            # secretsの値がエスケープを経て元のAPIキー文字列と完全一致することを確認する
            $parsed.properties.configuration.secrets.Count | Should Be 1
            $parsed.properties.configuration.secrets[0].name | Should Be 'api-key'
            $parsed.properties.configuration.secrets[0].value | Should Be 'key"with\backslash"and"quotes'

            $containers = $parsed.properties.template.containers
            $containers.Count | Should Be 2
        }
    }
}

Describe 'ContainerAppSpec.psm1 - Property-based Tests' {

    Context 'Property 6: Container AppスペックYAMLの必須構成要素' {

        # Feature: ollama-gpt-oss-container-apps, Property 6: 有効な設定値（モデル名、GPU種別、APIキー）
        # について、New-ContainerAppYamlが生成するYAML文字列は、常に (a) docker.io/ollama/ollama:latest
        # イメージを使うコンテナ定義、(b) nginx公式イメージを使うコンテナ定義、(c) external: trueかつ
        # targetPort: 8080のイングレス設定、を含む。
        # Validates: Requirements 3.1, 3.2, 3.3, 4.1, 4.3
        It '有効な設定値のランダムな組み合わせ100件以上で必須構成要素が常に含まれる' {

            function New-RandomModelNameForYaml {
                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:-._'
                $length = Get-Random -Minimum 1 -Maximum 30
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            function New-RandomAlphanumeric {
                param([int]$MinLength = 1, [int]$MaxLength = 40)
                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                $length = Get-Random -Minimum $MinLength -Maximum ($MaxLength + 1)
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            function New-RandomContainerAppName {
                $chars = 'abcdefghijklmnopqrstuvwxyz0123456789-'
                $length = Get-Random -Minimum 3 -Maximum 30
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            $gpuTypes = @('T4', 'A100')
            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $config = @{
                    ModelName        = New-RandomModelNameForYaml
                    GpuType          = $gpuTypes[(Get-Random -Minimum 0 -Maximum $gpuTypes.Count)]
                    ApiKey           = New-RandomAlphanumeric -MinLength 1 -MaxLength 64
                    ContainerAppName = New-RandomContainerAppName
                    EnvironmentId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test'
                }

                $yaml = New-ContainerAppYaml -Config $config

                # (a) Ollamaイメージを使うコンテナ定義
                $yaml.Contains('docker.io/ollama/ollama:latest') | Should Be $true

                # (b) nginxイメージを使うコンテナ定義
                $yaml.Contains('nginx:alpine') | Should Be $true

                # (c) external: true かつ targetPort: 8080 のイングレス設定
                $yaml.Contains('external: true') | Should Be $true
                $yaml.Contains('targetPort: 8080') | Should Be $true
            }
        }
    }
}
