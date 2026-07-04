Set-StrictMode -Version Latest

function Get-ModelReadinessResult {
    <#
    .SYNOPSIS
        モデル状態文字列からモデル準備状態判定結果を返す。
    .PARAMETER State
        判定対象の状態文字列（例: "Succeeded", "Failed", "Timeout", "Pulling"）。
    .OUTPUTS
        string ("Error", "Ready", "Pending" のいずれか)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$State
    )

    if ($State -eq 'Failed' -or $State -eq 'Timeout') {
        return 'Error'
    }

    if ($State -eq 'Succeeded') {
        return 'Ready'
    }

    return 'Pending'
}

function Write-DeploymentResult {
    <#
    .SYNOPSIS
        デプロイ完了フラグに基づき、curl実行例をコンソールに出力する。
    .DESCRIPTION
        Public_EndpointのURL自体は別ステップ（Container_App作成完了時点）で常に出力されるため、
        この関数は$IsCompleteが$trueの場合にのみcurl実行例を出力する。
    .PARAMETER IsComplete
        デプロイの全工程が完了したかどうかを示すブール値。
    .PARAMETER Url
        Public_EndpointのURL。
    .PARAMETER ApiKey
        設定済みのAPI_Key。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IsComplete,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$ApiKey
    )

    if (-not $IsComplete) {
        return
    }

    # Windows PowerShell 5.1 では `curl` が Invoke-WebRequest のエイリアスであり、かつ
    # シングルクォート内の二重引用符がネイティブコマンドへ渡る際に除去されるため、
    # `curl.exe` を使用し、JSON本体の引用符は `\"` としてエスケープする。
    Write-Host "curl.exe -X POST `"$Url/api/generate`" -H `"X-API-Key: $ApiKey`" -H `"Content-Type: application/json`" -d '{\`"model\`":\`"gpt-oss:20b\`",\`"prompt\`":\`"Hello\`",\`"stream\`":false}'"
}

function Write-ResultEndpointFile {
    <#
    .SYNOPSIS
        Public_EndpointのURL・API_Key・モデル名をMarkdownファイルへ書き出す。
    .PARAMETER Url
        Public_EndpointのURL。
    .PARAMETER ApiKey
        設定済みのAPI_Key。
    .PARAMETER ModelName
        デプロイされたOllamaモデル名。
    .PARAMETER IsComplete
        デプロイの全工程が完了したかどうかを示すブール値。
    .PARAMETER Path
        書き込み先のMarkdownファイルパス。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$ApiKey,

        [Parameter(Mandatory = $true)]
        [string]$ModelName,

        [Parameter(Mandatory = $true)]
        [bool]$IsComplete,

        [Parameter(Mandatory = $false)]
        [string]$Path = 'result-endpoint.md'
    )

    $statusText = if ($IsComplete) { 'Ready' } else { 'Pending' }

    $lines = @(
        '# Ollama Endpoint',
        '',
        "- URL: $Url",
        "- API_KEY: $ApiKey",
        "- MODEL: $ModelName",
        "- STATUS: $statusText"
    )

    if ($IsComplete) {
        $q = [char]34
        $ob = [char]123
        $cb = [char]125
        # Windows PowerShell 5.1 は、ネイティブコマンド（curl.exe）へシングルクォートで
        # 囲んだ引数を渡す際に、その内側の二重引用符（"）を除去してしまうため、JSON本体の
        # 各引用符は `\"`（バックスラッシュ + 引用符）としてエスケープする必要がある。
        # また、PowerShell では `curl` が Invoke-WebRequest のエイリアスであるため、本物の
        # curl を明示的に呼び出すよう `curl.exe` を使用する。
        $eq = '\' + $q
        # stream=false を指定し、応答を単一JSONオブジェクトとして返す（curl例では
        # ストリーミングの逐次JSON行が読みづらいため）。false はJSONの真偽値リテラルであり
        # 文字列ではないため、引用符では囲まない。
        $jsonBodyParts = @($ob, $eq, 'model', $eq, ':', $eq, $ModelName, $eq, ',', $eq, 'prompt', $eq, ':', $eq, 'Hello', $eq, ',', $eq, 'stream', $eq, ':', 'false', $cb)
        $jsonBody = -join $jsonBodyParts

        $curlExampleParts = @('curl.exe -X POST ', $q, $Url, '/api/generate', $q, ' -H ', $q, 'X-API-Key: ', $ApiKey, $q, ' -H ', $q, 'Content-Type: application/json', $q, ' -d ''', $jsonBody, '''')
        $curlExample = -join $curlExampleParts
        $lines += @(
            '',
            '## curl example (Windows PowerShell)',
            '',
            '```powershell',
            $curlExample,
            '```'
        )
    }

    $content = ($lines -join "`n") + "`n"

    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Get-ModelReadinessResult, Write-DeploymentResult, Write-ResultEndpointFile