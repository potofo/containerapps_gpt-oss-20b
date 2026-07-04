<#
.SYNOPSIS
    teardown.ps1 の削除確認プロンプトに関する具体例を検証する単体テスト（Pester）。

.DESCRIPTION
    Requirements: 8.3
    - Test-ShouldPromptForConfirmation: -Force指定時に$false（プロンプト非表示）、
      未指定時に$true（プロンプト表示）を返すことを検証
    - Test-DeletionConfirmed: 'y'/'Y'（前後空白を無視）のみ$trueを返し、
      それ以外（''/'n'/'yes'等）は$falseを返すことを検証
    - Read-DeletionConfirmation: -Force指定時はRead-Hostを呼び出さずに$trueを返し、
      未指定時はRead-Hostを呼び出して確認入力の結果を返すことを検証
#>

. (Join-Path $PSScriptRoot '..\teardown.ps1')

Describe 'teardown.ps1 - 削除確認プロンプトの具体例' {

    Context 'Test-ShouldPromptForConfirmation' {

        It '-Force指定時（$true）はプロンプトを表示しない（$falseを返す）' {
            $result = Test-ShouldPromptForConfirmation -Force $true

            $result | Should Be $false
        }

        It '-Force未指定時（$false）はプロンプトを表示する（$trueを返す）' {
            $result = Test-ShouldPromptForConfirmation -Force $false

            $result | Should Be $true
        }
    }

    Context 'Test-DeletionConfirmed - 具体例' {

        It "'y' は削除を実行してよいと判定する（`$true）" {
            Test-DeletionConfirmed -Answer 'y' | Should Be $true
        }

        It "'Y' は削除を実行してよいと判定する（`$true）" {
            Test-DeletionConfirmed -Answer 'Y' | Should Be $true
        }

        It "'n' は削除を実行しないと判定する（`$false）" {
            Test-DeletionConfirmed -Answer 'n' | Should Be $false
        }

        It "空文字列 '' は削除を実行しないと判定する（`$false）" {
            Test-DeletionConfirmed -Answer '' | Should Be $false
        }

        It "'yes' は完全一致ではないため削除を実行しないと判定する（`$false）" {
            Test-DeletionConfirmed -Answer 'yes' | Should Be $false
        }

        It "前後に空白を含む '  y  ' は空白がトリムされ削除を実行してよいと判定する（`$true）" {
            Test-DeletionConfirmed -Answer '  y  ' | Should Be $true
        }
    }

    Context 'Read-DeletionConfirmation - -Force指定時' {

        It '-Force $trueの場合はRead-Hostを呼び出さずに$trueを返す' {
            Mock Read-Host { return 'y' }

            $result = Read-DeletionConfirmation -ResourceGroupName 'test-rg' -Force $true

            $result | Should Be $true
            Assert-MockCalled Read-Host -Times 0
        }
    }

    Context 'Read-DeletionConfirmation - -Force未指定時' {

        It '-Force $falseの場合はRead-Hostを呼び出し、"y"回答時は$trueを返す' {
            Mock Read-Host { return 'y' }

            $result = Read-DeletionConfirmation -ResourceGroupName 'test-rg' -Force $false

            $result | Should Be $true
            Assert-MockCalled Read-Host -Times 1
        }

        It '-Force $falseの場合はRead-Hostを呼び出し、"n"回答時は$falseを返す' {
            Mock Read-Host { return 'n' }

            $result = Read-DeletionConfirmation -ResourceGroupName 'test-rg' -Force $false

            $result | Should Be $false
            Assert-MockCalled Read-Host -Times 1
        }
    }
}
