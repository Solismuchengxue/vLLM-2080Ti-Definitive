[CmdletBinding()]
param(
    [int]$MinimumPageFileMiB = 81920,
    [double]$MinimumCommitHeadroomGiB = 32
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
    Write-Host "HOST_PREFLIGHT=FAIL: $Message"
    exit 1
}

function To-GiB([double]$Bytes) {
    [math]::Round($Bytes / 1GB, 2)
}

Write-Host '=== SOLIS WINDOWS HOST PREFLIGHT ==='

$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$pfUsage = @(Get-CimInstance Win32_PageFileUsage)
$pfSetting = @(Get-CimInstance Win32_PageFileSetting)

if ($cs.AutomaticManagedPagefile) {
    Fail 'AutomaticManagedPagefile=True; expected fixed pagefile'
}

if ($pfUsage.Count -lt 1) {
    Fail 'no active Windows pagefile found'
}

Write-Host
Write-Host '=== PAGEFILE LIVE ==='

$pfUsage |
    Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage |
    Format-Table -AutoSize

$totalPageFileMiB = (
    $pfUsage |
    Measure-Object -Property AllocatedBaseSize -Sum
).Sum

if ($totalPageFileMiB -lt $MinimumPageFileMiB) {
    Fail (
        "active pagefile is ${totalPageFileMiB} MiB; " +
        "minimum is ${MinimumPageFileMiB} MiB"
    )
}

Write-Host
Write-Host '=== PAGEFILE CONFIG ==='

$pfSetting |
    Select-Object Name, InitialSize, MaximumSize |
    Format-Table -AutoSize

$validFixedSetting = $pfSetting | Where-Object {
    $_.InitialSize -ge $MinimumPageFileMiB -and
    $_.MaximumSize -ge $MinimumPageFileMiB
}

if (-not $validFixedSetting) {
    Fail (
        "no configured fixed pagefile >= " +
        "${MinimumPageFileMiB} MiB"
    )
}

Write-Host
Write-Host '=== SYSTEM COMMIT ==='

$memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory

$committed = [double]$memory.CommittedBytes
$limit = [double]$memory.CommitLimit
$headroom = $limit - $committed

Write-Host ("Committed : {0} GiB" -f (To-GiB $committed))
Write-Host ("Limit     : {0} GiB" -f (To-GiB $limit))
Write-Host ("Headroom  : {0} GiB" -f (To-GiB $headroom))

if ($limit -le 0) {
    Fail 'invalid Windows CommitLimit'
}

if ($headroom -lt ($MinimumCommitHeadroomGiB * 1GB)) {
    Fail (
        "commit headroom is $(To-GiB $headroom) GiB; " +
        "minimum is ${MinimumCommitHeadroomGiB} GiB"
    )
}

Write-Host
Write-Host '=== PHYSICAL MEMORY ==='
Write-Host (
    "Physical RAM : {0} GiB" -f
    ([math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 2))
)

Write-Host
Write-Host '=== RECENT EVENT 2004 ==='

$recent = @(
    Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Detector'
        Id           = 2004
        StartTime    = (Get-Date).AddHours(-24)
    } -ErrorAction SilentlyContinue
)

if ($recent.Count -gt 0) {
    Write-Warning (
        "found $($recent.Count) Resource-Exhaustion Event 2004 " +
        "record(s) in the last 24h"
    )
} else {
    Write-Host 'No Event 2004 in the last 24h.'
}

Write-Host
Write-Host 'HOST_PREFLIGHT=PASS'
exit 0
