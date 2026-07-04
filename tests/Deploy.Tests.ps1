<#
.SYNOPSIS
    deploy.ps1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 7.4
    - Test-SubscriptionSwitchNeeded: 現在のサブスクリプションIDと目的のサブスクリプションIDを比較し、
      両者が不一致の場合にのみ$true（切替が必要）を返し、一致する場合は$false（切替不要）を返すことを検証

    deploy.ps1 はトップレベル実行時にのみメイン処理（Azure CLI呼び出し等の副作用）を実行し、
    ドットソース（`. .\deploy.ps1`）時はヘルパー関数の定義のみを読み込む設計になっているため、
    このテストファイルではドットソースで安全に関数を読み込む。
#>

$deployScriptPath = Join-Path $PSScriptRoot '..\deploy.ps1'
. $deployScriptPath

Describe 'deploy.ps1 - Property-based Tests' {

    Context 'Property 14: サブスクリプション自動切替の条件一致性' {

        # Feature: ollama-gpt-oss-container-apps, Property 14: 現在のサブスクリプションID文字列と
        # `.env`で指定されたサブスクリプションID文字列の組み合わせについて、Test-SubscriptionSwitchNeeded は
        # 両者が不一致の場合にのみ$true（切替が必要）を返し、一致する場合は$false（切替不要）を返す。
        # Validates: Requirements 7.4
        It 'ランダムな2つのサブスクリプションID文字列の組み合わせ100件以上で不一致時のみ切替が必要と判定される' {

            # サブスクリプションIDらしいランダムな文字列（GUID形式）を生成する
            function New-RandomSubscriptionId {
                return [guid]::NewGuid().ToString()
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $currentSubscriptionId = New-RandomSubscriptionId

                # ランダムに「一致」ケースと「不一致」ケースを選択する
                $shouldMatch = (Get-Random -Minimum 0 -Maximum 2) -eq 0

                if ($shouldMatch) {
                    $targetSubscriptionId = $currentSubscriptionId
                    $expected = $false
                }
                else {
                    $targetSubscriptionId = New-RandomSubscriptionId
                    $expected = $true
                }

                $result = Test-SubscriptionSwitchNeeded -CurrentSubscriptionId $currentSubscriptionId -TargetSubscriptionId $targetSubscriptionId

                $result | Should Be $expected
            }
        }
    }
}

Describe 'deploy.ps1 - Property 13' {

    Context 'Property 13: Container_App更新失敗時の後続処理継続性' {

        # Feature: ollama-gpt-oss-container-apps, Property 13: Container_App更新処理の成功/失敗を
        # 表すランダムなブール値（UpdateSucceeded）について、Test-ShouldContinueAfterUpdate は
        # 値に関わらず常に$true（後続処理を実行する）という判定結果を返す。
        # Validates: Requirements 7.2
        It 'ランダムなブール値100件以上で値に関わらず常に後続処理が実行される判定になる' {

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $updateSucceeded = (Get-Random -Minimum 0 -Maximum 2) -eq 0

                $result = Test-ShouldContinueAfterUpdate -UpdateSucceeded $updateSucceeded

                $result | Should Be $true
            }
        }
    }
}
