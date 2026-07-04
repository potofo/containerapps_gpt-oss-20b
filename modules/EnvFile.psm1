<#
.SYNOPSIS
    .env ファイルのパース・書き込み・必須キー検証・APIキー生成を行う純粋関数群。

.DESCRIPTION
    Requirements: 1.1, 1.4, 1.5
    - Read-EnvFile: `KEY=VALUE` 形式の行を解析し、コメント行（`#`始まり）・空行を無視し、
      引用符（"/'）を除去して hashtable を返す。
    - Write-EnvFile: hashtable を .env 形式にシリアライズしてファイルに書き込む。
    - Test-RequiredKeys: 必須キー一覧から欠落キー名の配列を返す（API_Key は必須キー一覧に含めない）。
    - New-ApiKey: 暗号論的乱数（System.Security.Cryptography）を用いたランダム英数字文字列を生成する。
#>

Set-StrictMode -Version Latest

function ConvertTo-EnvEscapedValue {
    <#
    .SYNOPSIS
        値文字列中の `\` と `"` をバックスラッシュエスケープする（内部ヘルパー、非公開）。
    .DESCRIPTION
        Write-EnvFile が値を二重引用符で囲んで書き込む際に使用する。
        1文字ずつ処理することで、置換順序による誤変換を避ける。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\' -or $ch -eq '"') {
            [void]$sb.Append('\')
        }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

function ConvertFrom-EnvEscapedValue {
    <#
    .SYNOPSIS
        `ConvertTo-EnvEscapedValue` でエスケープされた値文字列を元に戻す（内部ヘルパー、非公開）。
    .DESCRIPTION
        Read-EnvFile が二重引用符で囲まれた値を検出した際に使用する。
        `\` の直後の1文字をリテラルとして扱い、2文字ずつ進めることで安全に復元する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.IndexOf('\') -lt 0) {
        return $Value
    }

    $sb = [System.Text.StringBuilder]::new()
    $i = 0
    $len = $Value.Length
    while ($i -lt $len) {
        $ch = $Value[$i]
        if ($ch -eq '\' -and ($i + 1) -lt $len) {
            [void]$sb.Append($Value[$i + 1])
            $i += 2
        }
        else {
            [void]$sb.Append($ch)
            $i += 1
        }
    }
    return $sb.ToString()
}

function Read-EnvFile {
    <#
    .SYNOPSIS
        .env ファイルを読み込み、KEY=VALUE のペアを hashtable として返す。
    .PARAMETER Path
        読み込む .env ファイルのパス。
    .OUTPUTS
        hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $result = @{}

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        return $result
    }

    $lines = Get-Content -Path $Path -ErrorAction Stop

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # 空行を無視
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        # コメント行（#始まり）を無視
        if ($trimmed.StartsWith('#')) {
            continue
        }

        # KEY=VALUE 形式の解析（最初の '=' で分割）
        $separatorIndex = $trimmed.IndexOf('=')
        if ($separatorIndex -lt 0) {
            continue
        }

        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()

        if ([string]::IsNullOrWhiteSpace($key)) {
            continue
        }

        # 引用符（"..." または '...'）を除去
        if ($value.Length -ge 2) {
            $firstChar = $value.Substring(0, 1)
            $lastChar = $value.Substring($value.Length - 1, 1)
            if ($firstChar -eq '"' -and $lastChar -eq '"') {
                # 二重引用符は Write-EnvFile が書き込む形式であり、内部の `\"` `\\` はエスケープされている
                $value = ConvertFrom-EnvEscapedValue -Value $value.Substring(1, $value.Length - 2)
            }
            elseif ($firstChar -eq "'" -and $lastChar -eq "'") {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $result[$key] = $value
    }

    return $result
}

function Write-EnvFile {
    <#
    .SYNOPSIS
        hashtable を .env 形式にシリアライズしてファイルに書き込む。
    .PARAMETER Path
        書き込み先の .env ファイルのパス。
    .PARAMETER Values
        書き込むキー/値の hashtable。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    # 値は常に二重引用符で囲み、`\` と `"` をエスケープして書き込む。
    # これにより、空文字列・前後の空白・引用符・`#`・`=` 等の任意の（改行を含まない）
    # 文字列値でも Read-EnvFile によるラウンドトリップが保証される。
    $lines = @()
    foreach ($key in $Values.Keys) {
        $escapedValue = ConvertTo-EnvEscapedValue -Value ([string]$Values[$key])
        $lines += "$key=`"$escapedValue`""
    }

    Set-Content -Path $Path -Value $lines -Encoding utf8
}

function Test-RequiredKeys {
    <#
    .SYNOPSIS
        必須キー一覧から欠落しているキー名の配列を返す。
    .PARAMETER Values
        検証対象の hashtable。
    .PARAMETER RequiredKeys
        必須キー名の配列（API_Key はここに含めない）。
    .OUTPUTS
        string[] 欠落キー名の配列（欠落がない場合は空配列）。
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredKeys
    )

    $missing = @()
    foreach ($key in $RequiredKeys) {
        if (-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
            $missing += $key
        }
    }

    # PowerShellは要素数0の配列を$nullに崩す場合があるため、常に配列として返す
    return [string[]]$missing
}

function New-ApiKey {
    <#
    .SYNOPSIS
        暗号論的乱数を用いたランダム英数字文字列を生成する。
    .PARAMETER Length
        生成する文字列の長さ（既定値: 32）。
    .OUTPUTS
        string
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int]$Length = 32
    )

    if ($Length -le 0) {
        throw "Length must be a positive integer."
    }

    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $charsLength = $chars.Length
    $bytes = [byte[]]::new($Length)

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $sb = [System.Text.StringBuilder]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        $index = $bytes[$i] % $charsLength
        [void]$sb.Append($chars[$index])
    }

    return $sb.ToString()
}

Export-ModuleMember -Function Read-EnvFile, Write-EnvFile, Test-RequiredKeys, New-ApiKey
