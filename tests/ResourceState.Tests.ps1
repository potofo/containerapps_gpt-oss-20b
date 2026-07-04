<#
.SYNOPSIS
    ResourceState.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 2.2, 7.1
    - Get-ResourceAction: リソースの存在有無を表すブール値から "Reuse"/"Create" を返す決定性を検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\ResourceState.psm1'
Import-Module $modulePath -Force

Describe 'ResourceState.psm1 - Property-based Tests' {

    Context 'Property 4: リソース存在有無に基づく再利用/作成の決定性' {

        # Feature: ollama-gpt-oss-container-apps, Property 4: リソースの存在有無を表すブール値について、
        # Get-ResourceActionは$trueのとき常に"Reuse"を、$falseのとき常に"Create"を返す。
        # Validates: Requirements 2.2, 7.1
        It 'ランダムなブール値100件以上でGet-ResourceActionの戻り値が存在有無と一致する' {

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $exists = [bool](Get-Random -Minimum 0 -Maximum 2)

                $result = Get-ResourceAction -Exists $exists

                if ($exists) {
                    $result | Should Be 'Reuse'
                }
                else {
                    $result | Should Be 'Create'
                }
            }
        }
    }

    Context 'Property 5: リージョン×GPU種別の組み合わせ検証の網羅性' {

        # Feature: ollama-gpt-oss-container-apps, Property 5: リージョン文字列とGPU種別文字列の組み合わせについて、
        # Test-RegionGpuSupportedは許可リスト（{westus3, swedencentral} × {T4, A100}）に含まれる場合に限り$trueを返す。
        # Validates: Requirements 2.4, 2.5
        It 'リージョン×GPU種別のランダムな組み合わせ100件以上でTest-RegionGpuSupportedの戻り値が許可リストと一致する' {

            # テスト内で独立にハードコードした期待値リスト（実装のミラーリングを避ける）
            $expectedAllowedCombinations = @(
                @{ Region = 'westus3'; Gpu = 'T4' },
                @{ Region = 'westus3'; Gpu = 'A100' },
                @{ Region = 'swedencentral'; Gpu = 'T4' },
                @{ Region = 'swedencentral'; Gpu = 'A100' }
            )

            # 許可リスト内外を含むリージョン候補プール（Test-RegionGpuSupportedのRegion引数は
            # 必須文字列パラメーターであり空文字列を許容しないため、空文字列は候補に含めない）
            $regionPool = @(
                'westus3',
                'swedencentral',
                'eastus',
                'japaneast',
                'westeurope',
                'WESTUS3',
                'westus3 ',
                '西部アメリカ3',
                (New-Guid).ToString()
            )

            # 許可リスト内外を含むGPU種別候補プール（同様の理由で空文字列は含めない）
            $gpuPool = @(
                'T4',
                'A100',
                'V100',
                'H100',
                'A100 ',
                't4',
                'RTX4090',
                (New-Guid).ToString(),
                'GPU-Unknown'
            )

            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $region = $regionPool[(Get-Random -Minimum 0 -Maximum $regionPool.Count)]
                $gpuType = $gpuPool[(Get-Random -Minimum 0 -Maximum $gpuPool.Count)]

                $result = Test-RegionGpuSupported -Region $region -GpuType $gpuType

                $expected = $false
                foreach ($combination in $expectedAllowedCombinations) {
                    if ($combination.Region -eq $region -and $combination.Gpu -eq $gpuType) {
                        $expected = $true
                        break
                    }
                }

                $result | Should Be $expected
            }
        }
    }
}
