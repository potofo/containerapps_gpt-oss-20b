<#
.SYNOPSIS
    AuthDecision.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 4.4, 4.5, 4.6
    - Test-ApiKeyAuthorized: ヘッダー値が$nullまたは空文字列なら$false、
      設定済みキーと完全一致する場合のみ$true、それ以外（値はあるが不一致）は$falseを返すことを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\AuthDecision.psm1'
Import-Module $modulePath -Force

Describe 'AuthDecision.psm1 - Property-based Tests' {

    Context 'Property 9: APIキー認可判定の正しさ（統合プロパティ）' {

        # Feature: ollama-gpt-oss-container-apps, Property 9: ヘッダー値（$null、空文字列、または任意の文字列）と
        # 設定済みAPIキー文字列の組み合わせについて、Test-ApiKeyAuthorizedはヘッダー値が$nullまたは空文字列の場合は
        # 常に$falseを返し、ヘッダー値が設定済みAPIキーと完全一致する場合のみ$trueを返し、それ以外（値はあるが不一致）
        # の場合は常に$falseを返す。
        # Validates: Requirements 4.4, 4.5, 4.6
        It 'ヘッダー値と設定済みAPIキーのランダムな組み合わせ100件以上で欠落時・不一致時は$false、完全一致時のみ$trueを返す' {

            # 設定済みAPIキーとして使うランダムな英数字文字列を生成する
            function New-RandomKeyString {
                param([int]$MinLength = 1, [int]$MaxLength = 40)

                $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                $length = Get-Random -Minimum $MinLength -Maximum ($MaxLength + 1)
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($chars[(Get-Random -Minimum 0 -Maximum $chars.Length)])
                }
                return $sb.ToString()
            }

            # 設定済みキーとは異なることが保証されたランダムな文字列を生成する
            function New-RandomMismatchedString {
                param([string]$ConfiguredKey)

                do {
                    $candidate = New-RandomKeyString -MinLength 1 -MaxLength 40
                } while ($candidate -ceq $ConfiguredKey)
                return $candidate
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $configuredKey = New-RandomKeyString -MinLength 1 -MaxLength 40

                # 4種類のケースをランダムに選択する: null / 空文字列 / 完全一致 / 不一致
                $caseIndex = Get-Random -Minimum 0 -Maximum 4

                switch ($caseIndex) {
                    0 {
                        # ヘッダー欠落（$null）
                        $headerValue = $null
                        $expected = $false
                    }
                    1 {
                        # ヘッダー欠落（空文字列）
                        $headerValue = ''
                        $expected = $false
                    }
                    2 {
                        # 完全一致
                        $headerValue = $configuredKey
                        $expected = $true
                    }
                    3 {
                        # 不一致（値はあるが設定済みキーとは異なる）
                        $headerValue = New-RandomMismatchedString -ConfiguredKey $configuredKey
                        $expected = $false
                    }
                }

                $result = Test-ApiKeyAuthorized -HeaderValue $headerValue -ConfiguredKey $configuredKey

                $result | Should Be $expected
            }
        }
    }
}
