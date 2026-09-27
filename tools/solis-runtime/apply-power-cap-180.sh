#!/usr/bin/env bash
set -euo pipefail

WIN_SMI="/mnt/c/Windows/System32/nvidia-smi.exe"
WIN_TASKS="/mnt/c/Windows/System32/schtasks.exe"
TASK_NAME='\Solis-AI-Power-180W'

TARGET_WATTS="180"

GPU0_UUID='GPU-d21daf2a-f8cc-c6d5-cb9d-1422779319f5'
GPU0_BUS='00000000:21:00.0'

GPU1_UUID='GPU-2d42853e-1ddb-ac75-9e87-6ff267fb9533'
GPU1_BUS='00000000:2D:00.0'

query_state() {
    "$WIN_SMI" \
        --query-gpu=uuid,pci.bus_id,power.limit,power.default_limit,power.min_limit,power.max_limit \
        --format=csv,noheader,nounits 2>/dev/null |
        tr -d '\r'
}

validate_state() {
    local mode=$1
    local state=$2

    POWER_STATE="$state" \
    VALIDATE_MODE="$mode" \
    TARGET_WATTS="$TARGET_WATTS" \
    GPU0_UUID="$GPU0_UUID" \
    GPU0_BUS="$GPU0_BUS" \
    GPU1_UUID="$GPU1_UUID" \
    GPU1_BUS="$GPU1_BUS" \
    python3 - <<'PY'
import os
import sys

target = float(os.environ["TARGET_WATTS"])
mode = os.environ["VALIDATE_MODE"]

expected = {
    os.environ["GPU0_UUID"]: os.environ["GPU0_BUS"],
    os.environ["GPU1_UUID"]: os.environ["GPU1_BUS"],
}

rows = [
    line.strip()
    for line in os.environ.get("POWER_STATE", "").splitlines()
    if line.strip()
]

if len(rows) != 2:
    print(f"ERROR: expected exactly 2 GPUs, got {len(rows)}", file=sys.stderr)
    raise SystemExit(2)

seen = {}

for row in rows:
    parts = [x.strip() for x in row.split(",")]

    if len(parts) != 6:
        print(f"ERROR: invalid NVIDIA row: {row}", file=sys.stderr)
        raise SystemExit(2)

    uuid, bus, current_s, default_s, min_s, max_s = parts

    if uuid not in expected:
        print(f"ERROR: unexpected GPU UUID: {uuid}", file=sys.stderr)
        raise SystemExit(2)

    if uuid in seen:
        print(f"ERROR: duplicate GPU UUID: {uuid}", file=sys.stderr)
        raise SystemExit(2)

    if bus.upper() != expected[uuid].upper():
        print(
            f"ERROR: PCI Bus mismatch for {uuid}: "
            f"expected {expected[uuid]}, got {bus}",
            file=sys.stderr,
        )
        raise SystemExit(2)

    try:
        current = float(current_s)
        default = float(default_s)
        minimum = float(min_s)
        maximum = float(max_s)
    except ValueError:
        print(f"ERROR: non-numeric power data for {uuid}", file=sys.stderr)
        raise SystemExit(2)

    if not minimum <= target <= maximum:
        print(
            f"ERROR: target {target:.0f}W outside live range "
            f"{minimum:.2f}-{maximum:.2f}W for {uuid}",
            file=sys.stderr,
        )
        raise SystemExit(2)

    seen[uuid] = {
        "current": current,
        "default": default,
        "minimum": minimum,
        "maximum": maximum,
    }

if set(seen) != set(expected):
    print("ERROR: expected GPU inventory is incomplete", file=sys.stderr)
    raise SystemExit(2)

if mode == "target":
    if any(abs(v["current"] - target) > 0.01 for v in seen.values()):
        raise SystemExit(1)

raise SystemExit(0)
PY
}

state=$(query_state) || {
    echo "GPU_POWER_CAP=FAIL: NVIDIA query failed" >&2
    exit 1
}

if ! validate_state preflight "$state"; then
    echo "GPU_POWER_CAP=FAIL: preflight rejected GPU identity/range" >&2
    exit 1
fi

if validate_state target "$state"; then
    printf '%s\n' "$state"
    echo "GPU_POWER_CAP=PASS (already 180W/180W)"
    exit 0
else
    rc=$?
    if (( rc != 1 )); then
        echo "GPU_POWER_CAP=FAIL: invalid GPU state" >&2
        exit 1
    fi
fi

echo "Applying fixed Solis AI power cap: 180W + 180W ..."

if ! "$WIN_TASKS" /Run /TN "$TASK_NAME" >/dev/null 2>&1; then
    echo "GPU_POWER_CAP=FAIL: scheduled task could not be started" >&2
    exit 1
fi

for _ in $(seq 1 20); do
    sleep 0.5

    if ! state=$(query_state); then
        continue
    fi

    if validate_state target "$state"; then
        printf '%s\n' "$state"
        echo "GPU_POWER_CAP=PASS"
        exit 0
    else
        rc=$?
        if (( rc == 2 )); then
            echo "GPU_POWER_CAP=FAIL: GPU identity/range changed during apply" >&2
            exit 1
        fi
    fi
done

echo "GPU_POWER_CAP=FAIL: 180W/180W readback timeout" >&2
printf '%s\n' "$state" >&2
exit 1
