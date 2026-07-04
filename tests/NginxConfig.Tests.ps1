<#
.SYNOPSIS
    NginxConfig.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 4.2
    - New-NginxConfigScript: 空文字列を除くランダムなAPIキー文字列に対し、生成される起動スクリプト文字列に
      そのAPIキー値を用いた完全一致比較ロジックが含まれることを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\NginxConfig.psm1'
Import-Module $modulePath -Force

Describe 'NginxConfig.psm1 - Property-based Tests' {

    Context 'Property 8: nginx設定生成におけるAPIキー照合ロジックの包含' {

        # Feature: ollama-gpt-oss-container-apps, Property 8: 空文字列を除くランダムなAPIキー文字列について、
        # New-NginxConfigScriptが生成する起動スクリプト文字列には、そのAPIキー値を用いた完全一致比較の
        # ロジックが含まれる。
        # Validates: Requirements 4.2
        It '空文字列を除くランダムなAPIキー文字列100件以上で生成スクリプトに完全一致比較ロジックが含まれる' {

            # New-ApiKeyが生成するような英数字のみのランダムなAPIキー文字列を生成する（空文字列は除く）
            function New-RandomApiKeyString {
                param([int]$MinLength = 1, [int]$MaxLength = 64)

                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                $length = Get-Random -Minimum $MinLength -Maximum ($MaxLength + 1)
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $apiKey = New-RandomApiKeyString -MinLength 1 -MaxLength 64

                $script = New-NginxConfigScript -ApiKey $apiKey

                # 生成された起動スクリプトに、そのAPIキー値を用いた完全一致比較ロジック
                # （$http_x_api_key != "<apiKey>"）が含まれることを検証する
                $expectedComparison = '$http_x_api_key != "' + $apiKey + '"'

                $script.Contains($expectedComparison) | Should Be $true
            }
        }
    }
}
