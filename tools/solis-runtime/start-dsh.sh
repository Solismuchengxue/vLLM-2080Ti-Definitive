#!/usr/bin/env bash
set -euo pipefail

WIN_TASKS="/mnt/c/Windows/System32/schtasks.exe"
PWSH="/mnt/c/Program Files/PowerShell/7/pwsh.exe"

TASK_NAME='\Solis-DSH'
PORT='3080'
EXPECTED_BIND='0.0.0.0'
DSH_BIN='C:\Users\smile\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js'

query_state() {
    "$PWSH" \
        -NoProfile \
        -NonInteractive \
        -Command '
$port = 3080
$expectedBind = "0.0.0.0"
$dshBin = "C:\Users\smile\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\lib\bin.js"

$listener = Get-NetTCPConnection `
    -State Listen `
    -LocalPort $port `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if (-not $listener) {
    "NONE"
    exit 0
}

$process = Get-CimInstance Win32_Process `
    -Filter ("ProcessId=" + $listener.OwningProcess) `
    -ErrorAction SilentlyContinue

if (
    $process -and
    $process.CommandLine -and
    $process.CommandLine.IndexOf(
        $dshBin,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -ge 0
) {
    if ($listener.LocalAddress -eq $expectedBind) {
        "DSH|$($listener.LocalAddress)|$($listener.LocalPort)|$($listener.OwningProcess)"
    } else {
        "DSH_WRONG_BIND|$($listener.LocalAddress)|$($listener.LocalPort)|$($listener.OwningProcess)"
    }
    exit 0
}

"OTHER|$($listener.LocalAddress)|$($listener.LocalPort)|$($listener.OwningProcess)"
' | tr -d '\r'
}

if [[ ! -x "$WIN_TASKS" ]]; then
    echo "DSH_START=FAIL: schtasks.exe not found" >&2
    exit 1
fi

if [[ ! -x "$PWSH" ]]; then
    echo "DSH_START=FAIL: Windows PowerShell 7 not found" >&2
    exit 1
fi

state=$(query_state) || {
    echo "DSH_START=FAIL: Windows state query failed" >&2
    exit 1
}

case "$state" in
    DSH\|"$EXPECTED_BIND"\|"$PORT"\|*)
        printf '%s\n' "$state"
        echo "DSH_START=PASS (already running)"
        exit 0
        ;;
    DSH_WRONG_BIND\|*)
        echo "DSH_START=FAIL: DSH is running with wrong bind: $state" >&2
        exit 1
        ;;
    OTHER\|*)
        echo "DSH_START=FAIL: port $PORT is owned by another process: $state" >&2
        exit 1
        ;;
    NONE)
        ;;
    *)
        echo "DSH_START=FAIL: unexpected Windows state: $state" >&2
        exit 1
        ;;
esac

if ! "$WIN_TASKS" /Query /TN "$TASK_NAME" >/dev/null 2>&1; then
    echo "DSH_START=FAIL: scheduled task not found: $TASK_NAME" >&2
    exit 1
fi

echo "Starting Solis DSH ..."

if ! "$WIN_TASKS" /Run /TN "$TASK_NAME" >/dev/null 2>&1; then
    echo "DSH_START=FAIL: scheduled task could not be started" >&2
    exit 1
fi

for _ in $(seq 1 40); do
    sleep 0.5

    state=$(query_state) || continue

    case "$state" in
        DSH\|"$EXPECTED_BIND"\|"$PORT"\|*)
            printf '%s\n' "$state"
            echo "DSH_START=PASS"
            exit 0
            ;;
        DSH_WRONG_BIND\|*)
            echo "DSH_START=FAIL: DSH started with wrong bind: $state" >&2
            exit 1
            ;;
        OTHER\|*)
            echo "DSH_START=FAIL: port $PORT was taken by another process: $state" >&2
            exit 1
            ;;
    esac
done

echo "DSH_START=FAIL: listen/readback timeout on $EXPECTED_BIND:$PORT" >&2
exit 1
