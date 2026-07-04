<#
.SYNOPSIS
    deploy.ps1 のモックを用いた統合テスト（Pester）。

.DESCRIPTION
    Requirements: 2.1, 2.2, 2.3, 7.1
    `az`コマンドをスタブ化し、deploy.ps1のヘルパー関数群を実際のメイン処理と同じ順序で
    呼び出した際に、以下を検証する。
      1. リソースが何も存在しない状態で実行したとき、
         Resource_Group作成 → Container_Apps_Environment作成 →
         GPUワークロードプロファイル追加 → Container_App作成 → Public_Endpoint取得
         の順序で`az`コマンドが呼び出されること
      2. Container_Apps_Environment / GPUワークロードプロファイル / Container_App が
         既存の場合、対応する作成（create）コマンドがスキップされ、他の手順は通常通り
         進行すること

    deploy.ps1 はトップレベル実行時にのみメイン処理（Azure CLI呼び出し等の副作用）を実行し、
    ドットソース（`. .\deploy.ps1`）時はヘルパー関数の定義のみを読み込む設計になっているため、
    このテストファイルではドットソースで安全に関数を読み込む。

    Azure CLI（`az`）は本テスト実行環境にインストールされていない可能性があり、
    その場合Pesterの`Mock`コマンドレットは対象コマンドの存在確認に失敗するため使用できない。
    そのため、PowerShellの関数定義がスコープ内で外部コマンドをシャドーイングできる仕組みを
    利用し、テスト内でローカルな`function az { ... }`を定義して`az`呼び出しを横取りする。
    このローカル関数は、渡された引数（`$args`）の先頭要素を見て呼び出し内容を判別し、
    スクリプトスコープの配列（`$script:CallOrder`）に呼び出し識別子を記録することで、
    呼び出し順序とスキップの有無を検証可能にする。
#>

$repoRoot = Join-Path $PSScriptRoot '..'
$deployScriptPath = Join-Path $repoRoot 'deploy.ps1'
. $deployScriptPath

Import-Module (Join-Path $repoRoot 'modules\ResourceState.psm1') -Force
Import-Module (Join-Path $repoRoot 'modules\ContainerAppSpec.psm1') -Force
# ContainerAppSpec.psm1 は内部で GpuProfile.psm1 を再インポートするため、
# Get-WorkloadProfile をこのテストのグローバルスコープでも解決できるように
# 最後に改めてインポートする（インポート順序が逆だと内部インポートに上書きされる）。
Import-Module (Join-Path $repoRoot 'modules\GpuProfile.psm1') -Force

function New-TestContainerAppConfig {
    <#
    .SYNOPSIS
        テスト用のContainer_App設定hashtableを生成する（テストヘルパー）。
    #>
    return @{
        ModelName        = 'gpt-oss:20b'
        GpuType          = 'T4'
        ApiKey           = 'test-api-key-value'
        ContainerAppName = 'ca-test'
        EnvironmentId    = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.App/managedEnvironments/cae-test'
    }
}

Describe 'deploy.ps1 - モックを用いた統合テスト（az呼び出し順序とスキップ動作）' {

    Context '新規作成シナリオ: 何も存在しない場合の呼び出し順序' {

        # Validates: Requirements 2.1, 2.2, 2.3, 7.1
        It 'Resource_Group→Container_Apps_Environment→ワークロードプロファイル→Container_App→Public_Endpointの順にazが呼び出される' {

            $script:CallOrder = @()

            # `az`が実際にインストールされていない環境でも横取りできるよう、
            # テストのローカルスコープで`az`という名前の関数を定義してシャドーイングする。
            function az {
                $global:LASTEXITCODE = 0

                if ($args[0] -eq 'group' -and $args[1] -eq 'create') {
                    $script:CallOrder += 'group-create'
                    return '{}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'show') {
                    $script:CallOrder += 'env-show'
                    return ''
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'create') {
                    $script:CallOrder += 'env-create'
                    return '{}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'workload-profile' -and $args[3] -eq 'add') {
                    $script:CallOrder += 'workload-profile-add'
                    return '{}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') {
                    $script:CallOrder += 'containerapp-show'
                    return ''
                }
                elseif ($args[0] -eq 'rest') {
                    # Publish-ContainerAppは実機のAzure環境での検証結果を踏まえ、
                    # `az containerapp create/update --yaml` ではなく `az rest --method PUT` で
                    # ARM REST APIを直接呼び出す実装になっている。
                    $script:CallOrder += 'containerapp-rest-put'
                    return '{}'
                }
                else {
                    throw "Unexpected az invocation: $($args -join ' ')"
                }
            }

            $resourceGroupName = 'rg-test'
            $location = 'westus3'
            $environmentName = 'cae-test'
            $subscriptionId = '00000000-0000-0000-0000-000000000000'
            $config = New-TestContainerAppConfig

            Initialize-ResourceGroup -ResourceGroupName $resourceGroupName -Location $location
            Initialize-ContainerAppsEnvironment -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -Location $location

            $workloadProfile = Get-WorkloadProfile -GpuType $config.GpuType
            Add-GpuWorkloadProfile -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -WorkloadProfile $workloadProfile

            Publish-ContainerApp -Config $config -ResourceGroupName $resourceGroupName -Location $location -SubscriptionId $subscriptionId

            # `az containerapp show` は `Get-PublicEndpointUrl` 内では `--query`/`--output tsv` を
            # 用いるため、専用のFQDN応答を返せるよう別途スタブする。
            function az {
                $global:LASTEXITCODE = 0

                if ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') {
                    $script:CallOrder += 'public-endpoint-show'
                    return 'ca-test.example.azurecontainerapps.io'
                }
                else {
                    throw "Unexpected az invocation: $($args -join ' ')"
                }
            }

            $url = Get-PublicEndpointUrl -ContainerAppName $config.ContainerAppName -ResourceGroupName $resourceGroupName

            $url | Should Be 'https://ca-test.example.azurecontainerapps.io'

            # 呼び出し順序の検証: Resource_Group作成 → env存在確認 → env作成 →
            # ワークロードプロファイル用env存在確認 → プロファイル追加 →
            # containerapp存在確認 → containerapp作成（az rest PUT）→ Public_Endpoint取得
            $script:CallOrder | Should Be @(
                'group-create',
                'env-show',
                'env-create',
                'env-show',
                'workload-profile-add',
                'containerapp-show',
                'containerapp-rest-put',
                'public-endpoint-show'
            )
        }
    }

    Context '既存リソース再利用シナリオ: 作成コマンドがスキップされる' {

        # Validates: Requirements 2.1, 2.2, 2.3, 7.1
        It 'Container_Apps_Environmentが既存の場合、env-createは呼び出されず後続手順は継続する' {

            $script:CallOrder = @()

            function az {
                $global:LASTEXITCODE = 0

                if ($args[0] -eq 'group' -and $args[1] -eq 'create') {
                    $script:CallOrder += 'group-create'
                    return '{}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'show') {
                    $script:CallOrder += 'env-show'
                    # 既存のContainer_Apps_Environmentを示すJSON
                    # （workloadProfilesに対象プロファイルが既に追加済みの状態を想定）
                    return '{"properties":{"workloadProfiles":[{"name":"Consumption-GPU-NC8as-T4"}]}}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'create') {
                    $script:CallOrder += 'env-create'
                    return '{}'
                }
                elseif ($args[0] -eq 'containerapp' -and $args[1] -eq 'env' -and $args[2] -eq 'workload-profile' -and $args[3] -eq 'add') {
                    $script:CallOrder += 'workload-profile-add'
                    return '{}'
                }
                else {
                    throw "Unexpected az invocation: $($args -join ' ')"
                }
            }

            $resourceGroupName = 'rg-test'
            $location = 'westus3'
            $environmentName = 'cae-test'
            $config = New-TestContainerAppConfig

            Initialize-ResourceGroup -ResourceGroupName $resourceGroupName -Location $location
            Initialize-ContainerAppsEnvironment -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -Location $location

            $workloadProfile = Get-WorkloadProfile -GpuType $config.GpuType
            Add-GpuWorkloadProfile -EnvironmentName $environmentName -ResourceGroupName $resourceGroupName -WorkloadProfile $workloadProfile

            # env-createは呼び出されないこと（既存のため再利用）
            # 注: Pester 3.xの`Should Contain`/`Should Not Contain`はファイル内容の検索用であり
            # 配列の要素検索には使えないため、PowerShell標準の`-contains`演算子を用いる。
            ($script:CallOrder -contains 'env-create') | Should Be $false

            # 注: 実機のAzure環境での検証により、`az containerapp env workload-profile add` は
            # design.mdの想定（冪等なコマンド）とは異なり、同名プロファイルが既に存在する場合は
            # エラーになることが判明したため、deploy.ps1側は既存時にコマンド自体をスキップするよう
            # 修正した。よってworkload-profile-addは呼び出されないことを検証する。
            ($script:CallOrder -contains 'workload-profile-add') | Should Be $false

            # 呼び出し順序自体は維持される（env-create・workload-profile-add抜きのシーケンス）
            $script:CallOrder | Should Be @(
                'group-create',
                'env-show',
                'env-show'
            )
        }

        # Validates: Requirements 2.1, 2.2, 2.3, 7.1
        It 'Container_Appが既存の場合、containerapp-createは呼び出されずcontainerapp-updateが実行され後続手順は継続する' {

            $script:CallOrder = @()
            $config = New-TestContainerAppConfig
            $resourceGroupName = 'rg-test'

            $location = 'westus3'
            $subscriptionId = '00000000-0000-0000-0000-000000000000'

            function az {
                $global:LASTEXITCODE = 0

                if ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') {
                    $script:CallOrder += 'containerapp-show'
                    # 既存のContainer_Appを示すJSON
                    return '{"name":"ca-test"}'
                }
                elseif ($args[0] -eq 'rest') {
                    # Publish-ContainerAppは実機のAzure環境での検証結果を踏まえ、
                    # `az containerapp create/update --yaml` ではなく `az rest --method PUT` で
                    # ARM REST APIを直接呼び出す実装になっている（新規作成/更新いずれも同一コマンド）。
                    $script:CallOrder += 'containerapp-rest-put'
                    return '{}'
                }
                else {
                    throw "Unexpected az invocation: $($args -join ' ')"
                }
            }

            Publish-ContainerApp -Config $config -ResourceGroupName $resourceGroupName -Location $location -SubscriptionId $subscriptionId

            $script:CallOrder | Should Be @('containerapp-show', 'containerapp-rest-put')

            # Public_Endpoint取得は既存/更新の成否に関わらず後続で実行できること
            function az {
                $global:LASTEXITCODE = 0

                if ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') {
                    $script:CallOrder += 'public-endpoint-show'
                    return 'ca-test.example.azurecontainerapps.io'
                }
                else {
                    throw "Unexpected az invocation: $($args -join ' ')"
                }
            }

            $url = Get-PublicEndpointUrl -ContainerAppName $config.ContainerAppName -ResourceGroupName $resourceGroupName

            $url | Should Be 'https://ca-test.example.azurecontainerapps.io'
            $script:CallOrder | Should Be @('containerapp-show', 'containerapp-rest-put', 'public-endpoint-show')
        }
    }
}
