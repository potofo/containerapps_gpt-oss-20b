<#
.SYNOPSIS
    DeploymentMonitor.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 5.3, 6.2
    - Get-ModelReadinessResult: 状態文字列が"Failed"または"Timeout"の場合は常に"Error"を返すことを検証
    - Write-DeploymentResult: デプロイ完了フラグが$falseのとき常にcurl実行例が出力されず、
      $trueのとき常に出力されることを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\DeploymentMonitor.psm1'
Import-Module $modulePath -Force

Describe 'DeploymentMonitor.psm1 - Property-based Tests' {

    Context 'Property 11: モデル準備状態判定の正しさ' {

        # Feature: ollama-gpt-oss-container-apps, Property 11: モデル状態を表す文字列
        # （"Succeeded", "Failed", "Timeout", "Pulling"等）について、Get-ModelReadinessResultは
        # 状態が"Failed"または"Timeout"を示す場合は常に"Error"を返す。
        # Validates: Requirements 5.3
        It 'ランダムな状態文字列100件以上で"Failed"/"Timeout"のとき常に"Error"を返す' {

            # 既知の状態文字列に加え、ランダムな英数字文字列も候補プールに含める
            function New-RandomStateString {
                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                $length = Get-Random -Minimum 1 -Maximum 20
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            $statePool = @('Succeeded', 'Failed', 'Timeout', 'Pulling', 'Running', 'Provisioning', 'Unknown')

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {

                # 既知の状態文字列とランダムな文字列を半々程度の割合で選択する
                if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) {
                    $state = $statePool[(Get-Random -Minimum 0 -Maximum $statePool.Count)]
                } else {
                    $state = New-RandomStateString
                }

                $result = Get-ModelReadinessResult -State $state

                if ($state -eq 'Failed' -or $state -eq 'Timeout') {
                    # "Failed"または"Timeout"のときは常に"Error"を返す
                    $result | Should Be 'Error'
                } else {
                    # それ以外の場合は"Error"を返さない
                    $result | Should Not Be 'Error'
                }
            }
        }
    }

    Context 'Write-ResultEndpointFile - 具体例（単体テスト）' {

        It '$IsComplete=$false のとき、URL/API_Key/MODEL/STATUS:Pending を含み、curl例を含まないMarkdownを書き出す' {
            $tempPath = Join-Path $TestDrive 'result-endpoint-pending.md'

            Write-ResultEndpointFile -Url 'https://example.azurecontainerapps.io' -ApiKey 'test-api-key-value' -ModelName 'gpt-oss:20b' -IsComplete $false -Path $tempPath

            $content = Get-Content -Path $tempPath -Raw

            $content | Should Match ([regex]::Escape('https://example.azurecontainerapps.io'))
            $content | Should Match ([regex]::Escape('test-api-key-value'))
            $content | Should Match ([regex]::Escape('gpt-oss:20b'))
            $content | Should Match 'STATUS: Pending'
            $content | Should Not Match 'curl'
        }

        It '$IsComplete=$true のとき、curl実行例を含むMarkdownを書き出す' {
            $tempPath = Join-Path $TestDrive 'result-endpoint-ready.md'

            Write-ResultEndpointFile -Url 'https://example.azurecontainerapps.io' -ApiKey 'test-api-key-value' -ModelName 'gpt-oss:20b' -IsComplete $true -Path $tempPath

            $content = Get-Content -Path $tempPath -Raw

            $content | Should Match 'STATUS: Ready'
            $content | Should Match 'curl'
            $content | Should Match ([regex]::Escape('X-API-Key: test-api-key-value'))
        }
    }

    Context 'Property 12: デプロイ完了フラグに基づく出力タイミングの一貫性' {

        # Feature: ollama-gpt-oss-container-apps, Property 12: デプロイ完了を表すブール値について、
        # Write-DeploymentResultはそれが$falseの場合は常にcurl実行例を出力せず、
        # $trueの場合は常にcurl実行例を出力する。
        # Validates: Requirements 6.2
        It 'ランダムなブール値100件以上で$falseのとき常に出力されず、$trueのとき常に出力される' {

            # UrlとApiKeyはランダムな英数字文字列として生成する
            function New-RandomToken {
                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                $length = Get-Random -Minimum 1 -Maximum 20
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {

                $isComplete = (Get-Random -Minimum 0 -Maximum 2) -eq 1
                $url = "https://" + (New-RandomToken) + ".example.com"
                $apiKey = New-RandomToken

                # Write-Hostの出力（情報ストリーム）を6>&1でリダイレクトして捕捉する
                $output = Write-DeploymentResult -IsComplete $isComplete -Url $url -ApiKey $apiKey 6>&1 | Out-String

                if ($isComplete) {
                    # $trueのときは常にcurl実行例が出力される
                    $output | Should Match 'curl'
                } else {
                    # $falseのときは常に何も出力されない
                    $output.Trim() | Should Be ''
                }
            }
        }
    }
}
