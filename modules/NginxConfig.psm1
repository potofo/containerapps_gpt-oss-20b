<#
.SYNOPSIS
    Auth_Proxy_Container（nginx）の起動コマンド文字列（shスクリプト）を生成する純粋関数群。

.DESCRIPTION
    Requirements: 4.1, 4.2, 4.3
    - New-NginxConfigScript: ヒアドキュメントでAPIキー値をリテラルとして埋め込んだ `nginx.conf` を
      作成し、`nginx -g "daemon off;"` を実行する起動シェルスクリプト文字列を返す。
      生成されるnginx設定は、`X-API-Key`ヘッダーが欠落・空の場合と、設定済みAPIキーと不一致の場合に
      401を返し、一致する場合のみ `http://localhost:11434`（Ollama_Container）へ`proxy_pass`する。
#>

Set-StrictMode -Version Latest

function ConvertTo-NginxDoubleQuotedValueEscaped {
    <#
    .SYNOPSIS
        nginx.conf内の二重引用符付き文字列リテラル（`"..."`）に安全に埋め込めるよう、
        値中の `\` と `"` をエスケープする（内部ヘルパー、非公開）。
    .DESCRIPTION
        生成されるnginx.confでは`if ($http_x_api_key != "__API_KEY__")`のように、APIキー値を
        nginxの二重引用符付き文字列として埋め込む。`\`と`"`をバックスラッシュエスケープすることで、
        値の中にこれらの文字が含まれていてもnginx設定の文字列リテラルとして正しく解釈される。
        ヒアドキュメント本体はシェル展開の対象外（`<<'EOF'`）のため、シェル側のエスケープは不要。
        `New-ApiKey`が生成するAPIキーは英数字のみのため実際には該当しないが、防御的に処理する。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value.Replace('\', '\\').Replace('"', '\"')
}

function New-NginxConfigScript {
    <#
    .SYNOPSIS
        Auth_Proxy_Containerの起動コマンド文字列（shスクリプト）を生成する。
    .DESCRIPTION
        生成されるスクリプトは以下を必ず行う:
        1. ヒアドキュメント（引用符付き終端子 `<<'EOF'`）を用いて `/etc/nginx/conf.d/default.conf`
           を作成する。引用符付き終端子により、ヒアドキュメント本体中の `$http_x_api_key`・`$host`
           （nginx変数）がシェルによって展開されず、nginxが解釈するリテラルとして書き込まれる。
        2. 生成される nginx.conf は、8080番ポートで待ち受け、`X-API-Key`ヘッダー
           （`$http_x_api_key`）が欠落・空文字列の場合は401を返し、`$ApiKey`と完全一致しない場合も
           401を返し、完全一致する場合のみ `http://localhost:11434`（Ollama_Container）へ
           `proxy_pass`する。
        3. `nginx -g "daemon off;"` を実行してnginxをフォアグラウンドで起動する。
        `$ApiKey` の値はヒアドキュメントへリテラルとして埋め込まれる（`envsubst`や実行時の
        環境変数展開には依存しない）。純粋関数のため、同一の入力からは常に同一の出力が得られる。
    .PARAMETER ApiKey
        `X-API-Key`ヘッダーとの比較に使用するAPIキー文字列。
    .OUTPUTS
        string : シェルスクリプト本体（`sh -c`等のラッパーは含まない）。呼び出し元
        （`ContainerAppSpec.psm1`）が`command: ["sh", "-c"]` + `args: [<この文字列>]`という
        形でコンテナのコマンド/引数に設定することを想定する。

        注: 以前の実装ではこの関数自体が`sh -c '<本体>'`という文字列全体を返していたが、
        Container Appsの`command: ["sh", "-c"]`と組み合わせた際に`sh -c`が二重にネストされ、
        Auth_Proxy_Containerが起動時にクラッシュループする不具合が実機のAzure環境での検証により
        判明した。そのため、この関数はスクリプト本体のみを返すよう変更した
        （`sh -c`ラッパーの付与は呼び出し元の責務とする）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiKey
    )

    $escapedApiKey = ConvertTo-NginxDoubleQuotedValueEscaped -Value $ApiKey

    $template = @'
cat <<'EOF' > /etc/nginx/conf.d/default.conf
server {
    listen 8080;
    location / {
        if ($http_x_api_key = "") { return 401; }
        if ($http_x_api_key != "__API_KEY__") { return 401; }
        proxy_pass http://localhost:11434;
        proxy_set_header Host $host;
    }
}
EOF
nginx -g "daemon off;"
'@

    $result = $template.Replace('__API_KEY__', $escapedApiKey)

    # 注: PowerShellのヒアストリング（`@'...'@`）はWindows環境ではCRLF（`\r\n`）で改行を
    # 生成する。このスクリプトはLinuxコンテナ内で`sh`に渡されるため、CRLFのまま渡すと
    # 各行末の`\r`がコマンドの一部として解釈され、"command not found"等のエラーで
    # コンテナがクラッシュループする（実機のAzure環境での検証により判明）。
    # そのため、明示的にLF（`\n`）のみに正規化する。
    return $result.Replace("`r`n", "`n").TrimEnd("`n")
}

Export-ModuleMember -Function New-NginxConfigScript
