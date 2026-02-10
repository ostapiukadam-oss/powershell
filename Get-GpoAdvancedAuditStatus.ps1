[CmdletBinding()]
param(
    [Parameter()]
    [string]$Domain = $env:USERDNSDOMAIN,

    [Parameter()]
    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Domain) {
    throw 'Nie udało się określić domeny. Podaj parametr -Domain.'
}

Import-Module GroupPolicy -ErrorAction Stop

$forceKey = 'HKLM\System\CurrentControlSet\Control\Lsa'
$forceValueName = 'SCENoApplyLegacyAuditPolicy'

$allGpos = Get-GPO -All -Domain $Domain
$results = foreach ($gpo in $allGpos) {
    $forcePolicy = Get-GPRegistryValue \
        -Guid $gpo.Id \
        -Domain $Domain \
        -Key $forceKey \
        -ValueName $forceValueName \
        -ErrorAction SilentlyContinue

    $forceSubcategories = $false
    if ($forcePolicy) {
        $rawValue = $forcePolicy.Value
        if ($rawValue -is [array]) {
            $rawValue = $rawValue[0]
        }

        try {
            $forceSubcategories = ([int]$rawValue -eq 1)
        }
        catch {
            $forceSubcategories = $false
        }
    }

    $xmlText = Get-GPOReport -Guid $gpo.Id -Domain $Domain -ReportType Xml
    $hasAdvancedAuditPolicy = $xmlText -match '(?i)<\s*AuditSetting\b|<\s*AuditPolicySubcategory\b|Advanced Audit Policy Configuration|\bSubcategory\b'

    [PSCustomObject]@{
        Domain                               = $Domain
        DisplayName                          = $gpo.DisplayName
        GpoId                                = $gpo.Id.Guid
        ForceAuditSubcategoryOverrideEnabled = $forceSubcategories
        AdvancedAuditPolicyConfigured        = $hasAdvancedAuditPolicy
    }
}

$results = $results | Sort-Object DisplayName
$results | Format-Table -AutoSize

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -Encoding UTF8 -NoTypeInformation
    Write-Host "\nWyniki zapisane do: $CsvPath"
}

$summary = [PSCustomObject]@{
    TotalGpos                          = $results.Count
    ForceSubcategoryEnabledCount       = ($results | Where-Object ForceAuditSubcategoryOverrideEnabled).Count
    AdvancedAuditPolicyConfiguredCount = ($results | Where-Object AdvancedAuditPolicyConfigured).Count
}

Write-Host '\nPodsumowanie:'
$summary | Format-List
