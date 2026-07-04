<#
.SYNOPSIS
    OllamaStartup.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 5.1, 5.2, 5.4
    - New-OllamaStartupScript: `ollama pull`と`ollama run`の対象が同一モデル名であり、
      `pull`が`run`より先に出現することを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\OllamaStartup.psm1'
Import-Module $modulePath -Force

Describe 'OllamaStartup.psm1 - Property-based Tests' {

    Context 'Property 10: Ollama起動スクリプトにおけるモデル名の一致とコマンド順序' {

        # Feature: ollama-gpt-oss-container-apps, Property 10: モデル名文字列について、
        # New-OllamaStartupScriptが生成するスクリプト文字列には、ollama pullとollama runの
        # 両方の対象として同一のモデル名が使用され、pullの呼び出しがrunの呼び出しより先に出現する。
        # Validates: Requirements 5.1, 5.2, 5.4
        It 'ランダムなモデル名文字列100件以上でpull/runの対象モデル名が一致し、pullがrunより先に出現する' {

            # Ollamaのモデル名で通常使用される文字種（英数字、コロン、ハイフン、ドット、
            # アンダースコア、スラッシュ）のみを用いる。これらの文字は
            # ConvertTo-ShDoubleQuotedEscape によるエスケープ（`\`と`"`のみが対象）の
            # 影響を受けないため、生成スクリプト内には元のモデル名がそのまま埋め込まれる。
            function New-RandomModelName {
                $modelNameChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:-._/'
                $length = Get-Random -Minimum 1 -Maximum 40
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($modelNameChars[(Get-Random -Minimum 0 -Maximum $modelNameChars.Length)])
                }
                return $sb.ToString()
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $modelName = New-RandomModelName

                $script = New-OllamaStartupScript -ModelName $modelName

                $expectedPull = 'ollama pull "' + $modelName + '"'
                $expectedRun = 'ollama run "' + $modelName + '"'

                $pullIndex = $script.IndexOf($expectedPull)
                $runIndex = $script.IndexOf($expectedRun)

                # pull/runの対象として同一のモデル名がそれぞれ完全な形で含まれること
                $pullIndex | Should BeGreaterThan -1
                $runIndex | Should BeGreaterThan -1

                # pullの呼び出しがrunの呼び出しより先に出現すること
                $pullIndex | Should BeLessThan $runIndex
            }
        }
    }
}
