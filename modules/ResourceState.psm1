<#
.SYNOPSIS
    Azureリソースの冪等性判定（再利用/作成の決定）とリージョン×GPU種別の許可判定を行う純粋関数群。

.DESCRIPTION
    Requirements: 2.2, 2.4, 2.5, 7.1
    - Get-ResourceAction: 存在有無のブール値から "Reuse"/"Create" を返す。
    - Test-RegionGpuSupported: {westus3, swedencentral} × {T4, A100} の許可リストと照合する。
#>

Set-StrictMode -Version Latest

# GPU/リージョン許可リスト（design.md の Data Models セクション参照）
$script:AllowedCombinations = @(
    @{ Region = 'westus3'; Gpu = 'T4' },
    @{ Region = 'westus3'; Gpu = 'A100' },
    @{ Region = 'swedencentral'; Gpu = 'T4' },
    @{ Region = 'swedencentral'; Gpu = 'A100' }
)

function Get-ResourceAction {
    <#
    .SYNOPSIS
        リソースの存在有無から "Reuse"/"Create" を返す。
    .PARAMETER Exists
        リソースが既に存在するかどうかを示すブール値。
    .OUTPUTS
        string ("Reuse" または "Create")
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Exists
    )

    if ($Exists) {
        return 'Reuse'
    }

    return 'Create'
}

function Test-RegionGpuSupported {
    <#
    .SYNOPSIS
        リージョンとGPU種別の組み合わせが許可リストに含まれるかを判定する。
    .PARAMETER Region
        判定対象のリージョン文字列（例: "westus3", "swedencentral"）。
    .PARAMETER GpuType
        判定対象のGPU種別文字列（例: "T4", "A100"）。
    .OUTPUTS
        bool
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Region,

        [Parameter(Mandatory = $true)]
        [string]$GpuType
    )

    foreach ($combination in $script:AllowedCombinations) {
        if ($combination.Region -eq $Region -and $combination.Gpu -eq $GpuType) {
            return $true
        }
    }

    return $false
}

Export-ModuleMember -Function Get-ResourceAction, Test-RegionGpuSupported
