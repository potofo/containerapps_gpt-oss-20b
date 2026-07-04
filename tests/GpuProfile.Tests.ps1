<#
.SYNOPSIS
    GpuProfile.psm1 のプロパティベーステスト（Pester）。

.DESCRIPTION
    Requirements: 3.2
    - Get-WorkloadProfile: GPU_Type（`T4`/`A100`）から対応する固定のワークロードプロファイル
      （ProfileType/FriendlyName/MaxCpu/MaxMemoryGiB）を返す正しさを検証
#>

$modulePath = Join-Path $PSScriptRoot '..\modules\GpuProfile.psm1'
Import-Module $modulePath -Force

Describe 'GpuProfile.psm1 - Property-based Tests' {

    Context 'Property 7: GPU種別からワークロードプロファイルへのマッピングの正しさ' {

        # Feature: ollama-gpt-oss-container-apps, Property 7: GPU_Type（T4またはA100）について、
        # Get-WorkloadProfileは対応する固定のワークロードプロファイルタイプとリソース上限を返し、
        # 返された上限値は常に正の値である。
        # Validates: Requirements 3.2
        It 'T4/A100のランダムな選択100件以上で固定のプロファイルタイプと正のリソース上限が返る' {

            $expectedProfiles = @{
                'T4'   = @{
                    ProfileType  = 'Consumption-GPU-NC8as-T4'
                    FriendlyName = 'Consumption-GPU-NC8as-T4'
                    MaxCpu       = 8
                    MaxMemoryGiB = 56
                }
                'A100' = @{
                    ProfileType  = 'Consumption-GPU-NC24-A100'
                    FriendlyName = 'Consumption-GPU-NC24-A100'
                    MaxCpu       = 24
                    MaxMemoryGiB = 220
                }
            }

            $gpuTypes = @('T4', 'A100')
            $iterationCount = 100

            for ($iteration = 0; $iteration -lt $iterationCount; $iteration++) {
                $gpuType = $gpuTypes[(Get-Random -Minimum 0 -Maximum $gpuTypes.Count)]

                $result = Get-WorkloadProfile -GpuType $gpuType

                $expected = $expectedProfiles[$gpuType]

                $result.ProfileType  | Should Be $expected.ProfileType
                $result.FriendlyName | Should Be $expected.FriendlyName
                $result.MaxCpu       | Should Be $expected.MaxCpu
                $result.MaxMemoryGiB | Should Be $expected.MaxMemoryGiB

                $result.MaxCpu       | Should BeGreaterThan 0
                $result.MaxMemoryGiB | Should BeGreaterThan 0
            }
        }
    }
}
