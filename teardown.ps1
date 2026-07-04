<#
.SYNOPSIS
    deploy.ps1で作成したAzureリソース（Resource_Group）を削除する。

.DESCRIPTION
    Requirements: 8.1, 8.2, 8.3
    design.md の「9. Teardown_Script (`teardown.ps1`)」に従い、以下の順序で処理する。
      1. `.env` から `AZURE_RESOURCE_GROUP` を読み込む
      2. `-Force` スイッチが指定されない限り、削除実行前に `Read-Host` で確認入力を要求する
         （確認されない場合は削除を行わずに終了する）
      3. `az group delete --name <rg> --yes --no-wait` を実行し、
         権限/APIエラー等により失敗した場合は削除を再試行せず、失敗内容を表示して処理を終了する

    このスクリプトはトップレベルで実行された場合にのみメイン処理を実行する。
    Pesterテストから `. .\teardown.ps1` のようにドットソースされた場合は、
    ヘルパー関数の定義のみが行われ、副作用のあるメイン処理（Read-Host・Azure CLI呼び出し等）は実行されない。
#>

param(
    [switch]$Force
)

Set-StrictMode -Version Latest
# 注: deploy.ps1と同様の理由（Windows PowerShell 5.1で外部コマンドのstderr出力が
# $LASTEXITCODEチェック前に終了エラーとしてスローされる問題を回避するため）で
# 'Continue' に設定する。エラー判定は明示的な $LASTEXITCODE チェックに一元化している。
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------------
# ヘルパー関数群（純粋関数・テスト容易な関数はここに定義する）
# -----------------------------------------------------------------------------

function Test-ShouldPromptForConfirmation {
    <#
    .SYNOPSIS
        `-Force` スイッチの指定有無から、削除確認プロンプトを表示すべきかどうかを判定する純粋関数。
    .DESCRIPTION
        Requirements: 8.3
        `-Force` が指定されている場合はプロンプトを表示せず（`$false`）、
        指定されていない場合はプロンプトを表示する（`$true`）。
    .PARAMETER Force
        `-Force` スイッチが指定されたかどうか。
    .OUTPUTS
        bool ($true: プロンプトを表示する, $false: プロンプトを表示しない)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Force
    )

    return -not $Force
}

function Test-DeletionConfirmed {
    <#
    .SYNOPSIS
        利用者からの確認入力文字列を受け取り、削除を実行してよいかどうかを判定する純粋関数。
    .DESCRIPTION
        Requirements: 8.3
        入力が `y` または `Y`（前後の空白を無視）の場合のみ削除を実行してよいと判定する。
        それ以外の入力（空文字列・`n`・その他任意の文字列）は削除しないと判定する。
    .PARAMETER Answer
        `Read-Host` 等で取得した利用者の確認入力文字列。
    .OUTPUTS
        bool ($true: 削除を実行する, $false: 削除を実行しない)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Answer
    )

    return $Answer.Trim() -in @('y', 'Y')
}

function Read-DeletionConfirmation {
    <#
    .SYNOPSIS
        `-Force` スイッチ未指定時に削除確認プロンプトを表示し、削除を実行してよいかどうかを判定する。
    .DESCRIPTION
        Requirements: 8.3
        `Test-ShouldPromptForConfirmation` の判定結果が `$false`（`-Force` 指定時）の場合は
        プロンプトを表示せず常に `$true`（削除を実行する）を返す。
        判定結果が `$true`（`-Force` 未指定時）の場合は `Read-Host` で確認入力を要求し、
        `Test-DeletionConfirmed` の判定結果を返す。
    .PARAMETER ResourceGroupName
        削除確認プロンプトに表示するResource_Group名。
    .PARAMETER Force
        `-Force` スイッチが指定されたかどうか。
    .OUTPUTS
        bool ($true: 削除を実行する, $false: 削除を実行しない)
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [bool]$Force
    )

    $shouldPrompt = Test-ShouldPromptForConfirmation -Force $Force

    if (-not $shouldPrompt) {
        return $true
    }

    $answer = Read-Host "Resource Group '$ResourceGroupName' を削除します。よろしいですか？ (y/N)"
    return Test-DeletionConfirmed -Answer $answer
}

function Remove-ResourceGroupAsync {
    <#
    .SYNOPSIS
        `az group delete --yes --no-wait` を実行してResource_Groupの削除を開始する。
    .DESCRIPTION
        Requirements: 8.1, 8.2
        design.md の「9. Teardown_Script」に従い、`az group delete --name <rg> --yes --no-wait`
        を実行する。`--no-wait` により削除完了を待たずに非同期でコマンドが返るため、
        実際の削除完了はAzure側で継続する。
        コマンドが非0終了コードを返した場合（権限エラー・APIエラー等）は、
        削除を再試行せず、失敗内容を表示してスクリプトを中断する
        （呼び出し元で `exit 1` させるため例外をスローする）。
    .PARAMETER ResourceGroupName
        削除対象のResource_Group名。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName
    )

    $errorOutput = az group delete --name $ResourceGroupName --yes --no-wait 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Resource_Groupの削除に失敗しました（名前: $ResourceGroupName）。失敗内容: $errorOutput"
        throw 'ResourceGroupDeleteFailed'
    }

    Write-Host "Resource Group '$ResourceGroupName' の削除を開始しました（--no-waitのため非同期実行です。完了はAzureポータル等でご確認ください）。"
}

# -----------------------------------------------------------------------------
# メイン処理
# -----------------------------------------------------------------------------
# ドットソース（`. .\teardown.ps1`）でPesterテストからヘルパー関数のみを読み込む場合、
# 以下のメイン処理（Read-Host・Azure CLI呼び出しを含む副作用のある処理）は実行しない。
if ($MyInvocation.InvocationName -ne '.') {

    $repoRoot = $PSScriptRoot
    $envFilePath = Join-Path $repoRoot '.env'

    try {
        # 1. .env から AZURE_RESOURCE_GROUP を読み込む。
        Import-Module (Join-Path $repoRoot 'modules\EnvFile.psm1') -Force
        $envValues = Read-EnvFile -Path $envFilePath
        $resourceGroupName = [string]$envValues['AZURE_RESOURCE_GROUP']

        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            Write-Error '`.env`に`AZURE_RESOURCE_GROUP`が設定されていません。'
            throw 'ResourceGroupNameMissing'
        }

        # 2. -Force 未指定時は確認入力を要求する。確認されない場合は削除せず終了する（正常終了）。
        $confirmed = Read-DeletionConfirmation -ResourceGroupName $resourceGroupName -Force $Force.IsPresent

        if (-not $confirmed) {
            Write-Host '削除をキャンセルしました。'
            exit 0
        }

        # 3. az group delete --yes --no-wait を実行する。失敗時は再試行せず失敗内容を表示して終了する。
        Remove-ResourceGroupAsync -ResourceGroupName $resourceGroupName
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }
}
