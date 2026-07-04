<#
.SYNOPSIS
    Ollama_Containerの起動コマンド文字列（shスクリプト）を生成する純粋関数群。

.DESCRIPTION
    Requirements: 5.1, 5.2, 5.3, 5.4
    - New-OllamaStartupScript: `ollama serve` をバックグラウンド起動し、ヘルスチェックループで
      APIが応答可能になるのを待ってから `ollama pull` を実行（失敗時は `exit 1`）、
      成功後に `ollama run` で明示的にモデルをロードする起動スクリプト文字列を返す。
#>

Set-StrictMode -Version Latest

function ConvertTo-ShDoubleQuotedEscape {
    <#
    .SYNOPSIS
        sh のダブルクォート文字列内に安全に埋め込めるよう、値中の `\` と `"` をエスケープする
        （内部ヘルパー、非公開）。
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

function New-OllamaStartupScript {
    <#
    .SYNOPSIS
        Ollama_Containerの起動コマンド文字列（shスクリプト）を生成する。
    .DESCRIPTION
        生成されるスクリプトは以下の順序を必ず守る:
        1. `ollama serve` をバックグラウンドで起動する
        2. ヘルスチェックループでAPIが応答可能になるまで待機する
        3. `ollama pull` で指定モデルを取得する（失敗時は `exit 1` でプロセスを終了する）
        4. `ollama run` で同一モデルを明示的にロードする
        pull/run の対象モデル名には、`$ModelName` の値をリテラルとして埋め込む
        （同一の文字列がpull/run双方で使用されるため、純粋関数として同じ入力からは
        常に同じ出力が得られる）。

        注: ヘルスチェックには`curl`ではなく`ollama list`（サーバー未起動時は接続エラーで
        非0終了コードを返す）を使用する。公式`ollama/ollama` Dockerイメージには`curl`が
        同梱されておらず、`curl`によるヘルスチェックは"command not found"で常に失敗し、
        `ollama pull`に到達できないことが実機のAzure環境での検証により判明した
        （既知の問題: https://github.com/ollama/ollama/issues/9781 ）。
    .PARAMETER ModelName
        pull/run対象のOllamaモデル名（例: "gpt-oss:20b"）。
    .OUTPUTS
        string : シェルスクリプト本体（`sh -c`等のラッパーは含まない）。呼び出し元
        （`ContainerAppSpec.psm1`）が`command: ["sh", "-c"]` + `args: [<この文字列>]`という
        形でコンテナのコマンド/引数に設定することを想定する。

        注: 以前の実装ではこの関数自体が`sh -c '<本体>'`という文字列全体を返していたが、
        Container Appsの`command: ["sh", "-c"]`と組み合わせた際に`sh -c`が二重にネストされ、
        Auth_Proxy_Container/Ollama_Containerが起動時にクラッシュループする不具合が
        実機のAzure環境での検証により判明した。そのため、この関数はスクリプト本体のみを
        返すよう変更した（`sh -c`ラッパーの付与は呼び出し元の責務とする）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModelName
    )

    $escapedModelName = ConvertTo-ShDoubleQuotedEscape -Value $ModelName

    $script = @"
ollama serve &
until ollama list >/dev/null 2>&1; do sleep 2; done
ollama pull "$escapedModelName" || exit 1
echo "" | ollama run "$escapedModelName" >/tmp/ollama-run.log 2>&1
wait
"@

    # 注: PowerShellのヒアストリング（`@"..."@`）はWindows環境ではCRLF（`\r\n`）で改行を
    # 生成する。このスクリプトはLinuxコンテナ内で`sh`に渡されるため、CRLFのまま渡すと
    # 各行末の`\r`がコマンドの一部として解釈され、"command not found"等のエラーで
    # コンテナがクラッシュループする（実機のAzure環境での検証により判明）。
    # そのため、明示的にLF（`\n`）のみに正規化する。
    $script = $script.Replace("`r`n", "`n")

    # 末尾の改行を除去する。
    $script = $script.TrimEnd("`n")

    return $script
}

Export-ModuleMember -Function New-OllamaStartupScript
