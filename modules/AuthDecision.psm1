<#
.SYNOPSIS
    APIキーヘッダーの認可判定ロジックを純粋関数としてモデル化したもの。

.DESCRIPTION
    Requirements: 4.4, 4.5, 4.6
    nginx設定自体はAzure上で動作するため直接ユニットテストできないが、その判定ロジック
    （「ヘッダー値が設定キーと完全一致する場合のみ許可」）をPowerShell側で純粋関数として
    モデル化し、設計の正しさを検証する。
    - Test-ApiKeyAuthorized: `$HeaderValue`が`$null`または空文字列なら`$false`、
      `$ConfiguredKey`と完全一致する場合のみ`$true`を返す。
#>

Set-StrictMode -Version Latest

function Test-ApiKeyAuthorized {
    <#
    .SYNOPSIS
        APIキーヘッダー値が設定済みキーと完全一致するかどうかを判定する。
    .PARAMETER HeaderValue
        リクエストヘッダーから取得したAPIキー値（未指定の場合は$nullまたは空文字列）。
    .PARAMETER ConfiguredKey
        設定済みのAPIキー文字列。
    .OUTPUTS
        bool ヘッダー値が$nullまたは空文字列の場合は常に$false、
        ConfiguredKeyと完全一致する場合のみ$true、それ以外は$false。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$HeaderValue,

        [Parameter(Mandatory = $true)]
        [string]$ConfiguredKey
    )

    if ([string]::IsNullOrEmpty($HeaderValue)) {
        return $false
    }

    return $HeaderValue -ceq $ConfiguredKey
}

Export-ModuleMember -Function Test-ApiKeyAuthorized
