Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'Solis-DSH'
$FirewallRuleName = 'Solis DSH LAN 3080'
$Port = 3080

$ProfileRoot = $env:USERPROFILE
$DshHome = Join-Path $ProfileRoot '.dsh'
$SolisDir = Join-Path $ProfileRoot '.solis'
$ScriptPath = Join-Path $SolisDir 'Start-SolisDsh.ps1'

$NodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
$DshBin = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'
$Pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

if (-not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) {
    throw "node.exe not found: $NodeExe"
}

if (-not (Test-Path -LiteralPath $DshBin -PathType Leaf)) {
    throw "DSH runtime not found: $DshBin"
}

if (-not (Test-Path -LiteralPath $DshHome -PathType Container)) {
    throw "DSH home not found: $DshHome"
}

New-Item -ItemType Directory -Force $SolisDir | Out-Null

@'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Port = 3080
$DshHome = Join-Path $env:USERPROFILE '.dsh'
$WorkDir = $env:USERPROFILE
$NodeExe = Join-Path $env:ProgramFiles 'nodejs\node.exe'
$DshBin = Join-Path $env:APPDATA 'npm\node_modules\@deepseek-ai\dsh\lib\bin.js'

function Get-PortOwner {
    $listener = Get-NetTCPConnection `
        -State Listen `
        -LocalPort $Port `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $listener) {
        return $null
    }

    $process = Get-CimInstance Win32_Process `
        -Filter "ProcessId=$($listener.OwningProcess)" `
        -ErrorAction SilentlyContinue

    [pscustomobject]@{
        Listener = $listener
        Process  = $process
    }
}

function Test-IsDshProcess($Process) {
    if (-not $Process) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Process.CommandLine)) {
        return $false
    }

    return $Process.CommandLine.IndexOf(
        $DshBin,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
}

if (-not (Test-Path -LiteralPath $NodeExe -PathType Leaf)) {
    Write-Error "NODE_NOT_FOUND=$NodeExe"
    exit 21
}

if (-not (Test-Path -LiteralPath $DshBin -PathType Leaf)) {
    Write-Error "DSH_BIN_NOT_FOUND=$DshBin"
    exit 22
}

if (-not (Test-Path -LiteralPath $DshHome -PathType Container)) {
    Write-Error "DSH_HOME_NOT_FOUND=$DshHome"
    exit 23
}

$env:DSH_HOME = $DshHome

$current = Get-PortOwner

if ($current) {
    if (Test-IsDshProcess $current.Process) {
        exit 0
    }

    Write-Error "PORT_${Port}_OCCUPIED_BY_NON_DSH_PID=$($current.Listener.OwningProcess)"
    exit 24
}

Start-Process `
    -FilePath $NodeExe `
    -ArgumentList @(
        $DshBin,
        'web',
        '--no-open'
    ) `
    -WorkingDirectory $WorkDir `
    -WindowStyle Hidden

$deadline = (Get-Date).AddSeconds(20)

do {
    Start-Sleep -Milliseconds 500

    $current = Get-PortOwner

    if ($current) {
        if (Test-IsDshProcess $current.Process) {
            exit 0
        }

        Write-Error "PORT_${Port}_TAKEN_DURING_START_PID=$($current.Listener.OwningProcess)"
        exit 25
    }
}
while ((Get-Date) -lt $deadline)

Write-Error "DSH_START_TIMEOUT_PORT=$Port"
exit 26
'@ | Set-Content $ScriptPath -Encoding utf8

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$User = $Identity.Name
$UserSid = $Identity.User.Value

$Action = New-ScheduledTaskAction `
    -Execute $Pwsh `
    -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""

$Principal = New-ScheduledTaskPrincipal `
    -UserId $User `
    -LogonType Interactive `
    -RunLevel Limited

$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 30) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $Action `
    -Principal $Principal `
    -Settings $Settings `
    -Description 'Solis DSH one-shot launcher for the local Web UI' `
    -Force | Out-Null

$existingFirewallRules = @(
    Get-NetFirewallRule `
        -DisplayName $FirewallRuleName `
        -ErrorAction SilentlyContinue
)

if ($existingFirewallRules.Count -eq 0) {
    New-NetFirewallRule `
        -DisplayName $FirewallRuleName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $Port `
        -RemoteAddress LocalSubnet `
        -Profile Private | Out-Null
}

$Task = Get-ScheduledTask -TaskName $TaskName

$TaskAccount = [Security.Principal.NTAccount]::new($Task.Principal.UserId)
$TaskSid = $TaskAccount.Translate(
    [Security.Principal.SecurityIdentifier]
).Value

if ($TaskSid -ne $UserSid) {
    throw "Task principal SID mismatch: expected $UserSid ($User), got $TaskSid ($($Task.Principal.UserId))"
}

if ($Task.Principal.RunLevel -ne 'Limited') {
    throw "Task run level mismatch: $($Task.Principal.RunLevel)"
}

Write-Host "TASK_INSTALLED=$($Task.TaskName)"
Write-Host "TASK_STATE=$($Task.State)"
Write-Host "TASK_USER=$($Task.Principal.UserId)"
Write-Host "TASK_USER_SID=$TaskSid"
Write-Host "TASK_RUN_LEVEL=$($Task.Principal.RunLevel)"
Write-Host "DSH_SCRIPT=$ScriptPath"
Write-Host "DSH_HOME=$DshHome"

$FirewallRule = Get-NetFirewallRule `
    -DisplayName $FirewallRuleName `
    -ErrorAction Stop |
    Select-Object -First 1

$FirewallPort = $FirewallRule |
    Get-NetFirewallPortFilter

$FirewallAddress = $FirewallRule |
    Get-NetFirewallAddressFilter

if ($FirewallRule.Enabled -ne 'True') {
    throw "Firewall rule is disabled: $FirewallRuleName"
}

if ($FirewallRule.Direction -ne 'Inbound' -or $FirewallRule.Action -ne 'Allow') {
    throw "Firewall rule direction/action mismatch: $FirewallRuleName"
}

if ($FirewallPort.Protocol -ne 'TCP' -or
    [string]$FirewallPort.LocalPort -ne [string]$Port) {
    throw "Firewall rule port mismatch: $FirewallRuleName"
}

if ($FirewallAddress.RemoteAddress -notcontains 'LocalSubnet') {
    throw "Firewall rule is not restricted to LocalSubnet: $FirewallRuleName"
}

Write-Host "FIREWALL_RULE=$FirewallRuleName"
Write-Host "FIREWALL_PORT=$Port"
Write-Host "FIREWALL_REMOTE=LocalSubnet"
Write-Host "FIREWALL_PROFILE=Private"

$Task.Actions |
    Select-Object Execute, Arguments |
    Format-Table -AutoSize
