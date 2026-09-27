Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'Solis-AI-Power-180W'
$Smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'

if (-not (Test-Path -LiteralPath $Smi -PathType Leaf)) {
    throw "nvidia-smi.exe not found: $Smi"
}

$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$Action0 = New-ScheduledTaskAction `
    -Execute $Smi `
    -Argument '-i GPU-d21daf2a-f8cc-c6d5-cb9d-1422779319f5 -pl 180'

$Action1 = New-ScheduledTaskAction `
    -Execute $Smi `
    -Argument '-i GPU-2d42853e-1ddb-ac75-9e87-6ff267fb9533 -pl 180'

$Actions = @(
    $Action0
    $Action1
)

$Principal = New-ScheduledTaskPrincipal `
    -UserId $User `
    -LogonType Interactive `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 30) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Actions `
    -Principal $Principal `
    -Settings $Settings `
    -Description 'Fixed Solis AI power cap: GPU0=180W, GPU1=180W' `
    -Force | Out-Null

$Task = Get-ScheduledTask -TaskName $TaskName

Write-Host "TASK_INSTALLED=$($Task.TaskName)"
Write-Host "TASK_STATE=$($Task.State)"
Write-Host "TASK_USER=$User"

$Task.Actions |
    Select-Object Execute, Arguments |
    Format-Table -AutoSize
