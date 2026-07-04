<#
.SYNOPSIS
    EnvFile.psm1 の具体例・エッジケースを検証する単体テスト（Pester）。

.DESCRIPTION
    Requirements: 1.1, 1.4
    - Read-EnvFile: コメント行・空行・引用符付き値・末尾スペースを含む.envサンプルの解析結果を検証
    - Test-RequiredKeys: 必須キーが全て揃っている場合に空配列を返すことを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\EnvFile.psm1'
Import-Module $modulePath -Force

Describe 'EnvFile.psm1' {

    Context 'Read-EnvFile - 具体例・エッジケース' {

        It 'コメント行・空行・引用符付き値・末尾スペースを含む.envサンプルを正しく解析する' {
            $envContent = @(
                '# これはコメント行です',
                '',
                '   ',
                'AZURE_SUBSCRIPTION_ID=11111111-1111-1111-1111-111111111111',
                '# 別のコメント行 KEY=VALUE のように見えるが無視される',
                'AZURE_RESOURCE_GROUP="rg-ollama-gptoss20b"   ',
                "OLLAMA_MODEL='gpt-oss:20b'",
                '   AZURE_LOCATION   =   westus3   ',
                'API_KEY=  ',
                'EMPTY_QUOTED=""'
            )

            $tempPath = Join-Path $TestDrive '.env'
            Set-Content -Path $tempPath -Value $envContent -Encoding utf8

            $result = Read-EnvFile -Path $tempPath

            # コメント行・空行は無視され、有効なキーのみが含まれる
            $result.Count | Should Be 6

            # 通常のKEY=VALUE行
            $result['AZURE_SUBSCRIPTION_ID'] | Should Be '11111111-1111-1111-1111-111111111111'

            # 二重引用符が除去される（末尾スペースはトリムされる）
            $result['AZURE_RESOURCE_GROUP'] | Should Be 'rg-ollama-gptoss20b'

            # シングルクォートが除去される
            $result['OLLAMA_MODEL'] | Should Be 'gpt-oss:20b'

            # キー側・値側の前後の空白がトリムされる
            $result['AZURE_LOCATION'] | Should Be 'westus3'

            # 値が空白のみの場合は空文字列になる
            $result['API_KEY'] | Should Be ''

            # 引用符のみ（空文字列を引用符で囲んだ値）は空文字列になる
            $result['EMPTY_QUOTED'] | Should Be ''
        }

        It '引用符が片方にしか無い場合は引用符を除去しない' {
            $envContent = @(
                'KEY1="unmatched',
                "KEY2=unmatched'"
            )

            $tempPath = Join-Path $TestDrive 'unmatched.env'
            Set-Content -Path $tempPath -Value $envContent -Encoding utf8

            $result = Read-EnvFile -Path $tempPath

            $result['KEY1'] | Should Be '"unmatched'
            $result['KEY2'] | Should Be "unmatched'"
        }

        It '存在しないファイルパスの場合は空のhashtableを返す' {
            $nonExistentPath = Join-Path $TestDrive 'does-not-exist.env'

            $result = Read-EnvFile -Path $nonExistentPath

            $result.Count | Should Be 0
        }

        It '"="を含まない行は無視される' {
            $envContent = @(
                'NOEQUALSIGN',
                'VALID_KEY=valid_value'
            )

            $tempPath = Join-Path $TestDrive 'noequals.env'
            Set-Content -Path $tempPath -Value $envContent -Encoding utf8

            $result = Read-EnvFile -Path $tempPath

            $result.Count | Should Be 1
            $result['VALID_KEY'] | Should Be 'valid_value'
        }
    }

    Context 'Test-RequiredKeys - 具体例・エッジケース' {

        It '必須キーが全て揃っている場合は空配列を返す' {
            $values = @{
                'AZURE_SUBSCRIPTION_ID'              = '11111111-1111-1111-1111-111111111111'
                'AZURE_TENANT_ID'                     = '22222222-2222-2222-2222-222222222222'
                'AZURE_RESOURCE_GROUP'                = 'rg-ollama-gptoss20b'
                'AZURE_LOCATION'                      = 'westus3'
                'AZURE_CONTAINER_APPS_ENVIRONMENT'    = 'cae-ollama-gptoss20b'
                'AZURE_CONTAINER_APP_NAME'            = 'ca-ollama-gptoss20b'
                'AZURE_GPU_TYPE'                       = 'T4'
                'OLLAMA_MODEL'                         = 'gpt-oss:20b'
            }
            $requiredKeys = @(
                'AZURE_SUBSCRIPTION_ID',
                'AZURE_TENANT_ID',
                'AZURE_RESOURCE_GROUP',
                'AZURE_LOCATION',
                'AZURE_CONTAINER_APPS_ENVIRONMENT',
                'AZURE_CONTAINER_APP_NAME',
                'AZURE_GPU_TYPE',
                'OLLAMA_MODEL'
            )

            $missing = @(Test-RequiredKeys -Values $values -RequiredKeys $requiredKeys)

            $missing.Count | Should Be 0
        }

        It '必須キーが1つ欠落している場合はそのキー名を返す' {
            $values = @{
                'AZURE_SUBSCRIPTION_ID' = '11111111-1111-1111-1111-111111111111'
            }
            $requiredKeys = @('AZURE_SUBSCRIPTION_ID', 'AZURE_TENANT_ID')

            # PowerShellは要素数1の配列をパイプライン経由でスカラーに崩す場合があるため、
            # @() で明示的に配列化してから検証する
            $missing = @(Test-RequiredKeys -Values $values -RequiredKeys $requiredKeys)

            $missing.Count | Should Be 1
            $missing[0] | Should Be 'AZURE_TENANT_ID'
        }

        It '必須キーの値が空白のみの場合は欠落として検出する' {
            $values = @{
                'AZURE_SUBSCRIPTION_ID' = '   '
            }
            $requiredKeys = @('AZURE_SUBSCRIPTION_ID')

            $missing = @(Test-RequiredKeys -Values $values -RequiredKeys $requiredKeys)

            $missing.Count | Should Be 1
            $missing[0] | Should Be 'AZURE_SUBSCRIPTION_ID'
        }
    }
}

Describe 'EnvFile.psm1 - Property-based Tests' {

    Context 'Property 1: .env読み書きのラウンドトリップ' {

        # Feature: ollama-gpt-oss-container-apps, Property 1: 有効な文字列キーと値のペアの集合について、
        # Write-EnvFileで書き込んだ後にRead-EnvFileで読み込むと、元のキーと値の集合と一致するハッシュテーブルが得られる。
        # Validates: Requirements 1.1
        It 'ランダムなキー/値ペア集合100件以上でWrite-EnvFile→Read-EnvFileのラウンドトリップが元の集合と一致する' {

            # キーは英数字とアンダースコアのみで構成されたランダム文字列を生成する
            function New-RandomEnvKey {
                $keyChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'
                $length = Get-Random -Minimum 1 -Maximum 20
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($keyChars[(Get-Random -Minimum 0 -Maximum $keyChars.Length)])
                }
                return $sb.ToString()
            }

            # 値は改行を含まない任意の文字列（空文字列・空白・引用符・記号・Unicode文字を含む）を生成する
            # 候補は「トークン」の配列とし、各トークンを丸ごと選択して連結する。
            # サロゲートペア文字（絵文字等）を1コードユニット単位で切り出すと不正な
            # ローンサロゲートが生じてしまうため、個々の文字ではなくトークン単位で扱う。
            function New-RandomEnvValue {
                $tokenPool = @(
                    'A', 'b', 'Z', '0', '9', ' ', "`t", '!', '@', '#', '$', '%', '^', '&',
                    '*', '(', ')', '-', '+', '=', '[', ']', '{', '}', '|', ';', ':', ',',
                    '.', '<', '>', '?', '/', '~', '`', '"', "'", '\',
                    'あ', 'い', '漢', '字', 'テスト', '🎉'
                )
                $length = Get-Random -Minimum 0 -Maximum 40
                if ($length -eq 0) {
                    return ''
                }
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($tokenPool[(Get-Random -Minimum 0 -Maximum $tokenPool.Length)])
                }
                return $sb.ToString()
            }

            # 1つのランダムなキー/値ペア集合（hashtable）を生成する（キーは一意）
            function New-RandomEnvValueSet {
                $pairCount = Get-Random -Minimum 1 -Maximum 20
                $values = @{}
                $attempts = 0
                while ($values.Count -lt $pairCount -and $attempts -lt ($pairCount * 10)) {
                    $attempts++
                    $key = New-RandomEnvKey
                    if (-not $values.ContainsKey($key)) {
                        $values[$key] = New-RandomEnvValue
                    }
                }
                return $values
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $originalValues = New-RandomEnvValueSet
                $tempPath = Join-Path $TestDrive "roundtrip-$iteration.env"

                Write-EnvFile -Path $tempPath -Values $originalValues
                $roundTrippedValues = Read-EnvFile -Path $tempPath

                # キーの集合が完全一致すること
                $originalKeys = @($originalValues.Keys | Sort-Object)
                $roundTrippedKeys = @($roundTrippedValues.Keys | Sort-Object)
                (Compare-Object -ReferenceObject $originalKeys -DifferenceObject $roundTrippedKeys) | Should Be $null

                # 各キーの値が完全一致すること
                foreach ($key in $originalValues.Keys) {
                    $roundTrippedValues[$key] | Should Be $originalValues[$key]
                }
            }
        }
    }

    Context 'Property 2: 必須項目欠落検出の完全性' {

        # Feature: ollama-gpt-oss-container-apps, Property 2: 必須キー一覧の任意の空でない部分集合を欠落させた
        # 設定マップについて、Test-RequiredKeysは欠落しているキー名をすべて含む配列を返し、
        # 欠落キーが存在しない場合は空配列を返す。
        # Validates: Requirements 1.4
        It '必須キー一覧のランダムな空でない部分集合を欠落させたケース100件以上で欠落キーを全て検出する' {

            # design.md の Environment_Configuration_File スキーマにおける必須キー一覧（API_KEYは含めない）
            $requiredKeys = @(
                'AZURE_SUBSCRIPTION_ID',
                'AZURE_TENANT_ID',
                'AZURE_RESOURCE_GROUP',
                'AZURE_LOCATION',
                'AZURE_CONTAINER_APPS_ENVIRONMENT',
                'AZURE_CONTAINER_APP_NAME',
                'AZURE_GPU_TYPE',
                'OLLAMA_MODEL'
            )

            # 有効な非空値のランダムな文字列を生成する（値そのものはTest-RequiredKeysの検証対象外）
            function New-RandomValidValue {
                $valueChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'
                $length = Get-Random -Minimum 1 -Maximum 20
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($valueChars[(Get-Random -Minimum 0 -Maximum $valueChars.Length)])
                }
                return $sb.ToString()
            }

            # $requiredKeys のランダムな空でない部分集合を選ぶ（欠落させるキー集合）
            function New-RandomNonEmptySubset {
                param([string[]]$Keys)

                $subsetSize = Get-Random -Minimum 1 -Maximum ($Keys.Count + 1)
                $shuffled = @($Keys | Sort-Object { Get-Random })
                return @($shuffled[0..($subsetSize - 1)])
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $omittedKeys = @(New-RandomNonEmptySubset -Keys $requiredKeys)

                # 欠落させないキーには有効な値を設定し、欠落させるキーはhashtableに含めない
                $values = @{}
                foreach ($key in $requiredKeys) {
                    if ($omittedKeys -notcontains $key) {
                        $values[$key] = New-RandomValidValue
                    }
                }

                $missing = @(Test-RequiredKeys -Values $values -RequiredKeys $requiredKeys)

                # 欠落キー集合が、欠落させたキー集合と（順序に関わらず）完全一致すること
                $sortedMissing = @($missing | Sort-Object)
                $sortedOmitted = @($omittedKeys | Sort-Object)

                $missing.Count | Should Be $omittedKeys.Count
                (Compare-Object -ReferenceObject $sortedOmitted -DifferenceObject $sortedMissing) | Should Be $null
            }
        }

        It '欠落キーが存在しない場合は空配列を返す（境界ケース、100件以上）' {

            $requiredKeys = @(
                'AZURE_SUBSCRIPTION_ID',
                'AZURE_TENANT_ID',
                'AZURE_RESOURCE_GROUP',
                'AZURE_LOCATION',
                'AZURE_CONTAINER_APPS_ENVIRONMENT',
                'AZURE_CONTAINER_APP_NAME',
                'AZURE_GPU_TYPE',
                'OLLAMA_MODEL'
            )

            function New-RandomValidValue {
                $valueChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-'
                $length = Get-Random -Minimum 1 -Maximum 20
                $sb = [System.Text.StringBuilder]::new()
                for ($i = 0; $i -lt $length; $i++) {
                    [void]$sb.Append($valueChars[(Get-Random -Minimum 0 -Maximum $valueChars.Length)])
                }
                return $sb.ToString()
            }

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $values = @{}
                foreach ($key in $requiredKeys) {
                    $values[$key] = New-RandomValidValue
                }

                $missing = @(Test-RequiredKeys -Values $values -RequiredKeys $requiredKeys)

                $missing.Count | Should Be 0
            }
        }
    }

    Context 'Property 3: API_Key自動生成の妥当性と一意性' {

        # Feature: ollama-gpt-oss-container-apps, Property 3: New-ApiKeyは指定された任意の正の長さについて、
        # その長さと等しく英数字のみで構成された文字列を返し、複数回の呼び出しで生成された値は互いに重複しない。
        # Validates: Requirements 1.5
        It 'ランダムな長さ100件以上でNew-ApiKeyの文字種制約（英数字のみ）と長さの一致を検証する' {

            $iterationCount = 100
            $alphanumericPattern = '^[A-Za-z0-9]+$'

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $randomLength = Get-Random -Minimum 1 -Maximum 65

                $apiKey = New-ApiKey -Length $randomLength

                # 生成された文字列の長さが指定した長さと一致すること
                $apiKey.Length | Should Be $randomLength

                # 生成された文字列が英数字のみで構成されていること
                $apiKey | Should Match $alphanumericPattern
            }
        }

        It '複数回の呼び出し（100件以上）で生成されたAPI_Keyが互いに重複しないことを検証する' {

            $iterationCount = 100
            $generatedKeys = New-Object System.Collections.Generic.List[string]

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $generatedKeys.Add((New-ApiKey -Length 32))
            }

            # 重複が無ければ、一意な値の個数は生成回数と一致する
            $uniqueCount = @($generatedKeys | Sort-Object -Unique).Count
            $uniqueCount | Should Be $generatedKeys.Count
        }
    }
}
