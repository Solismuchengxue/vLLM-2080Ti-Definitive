#!/usr/bin/env bash
set -euo pipefail

EXPECTED_GPUS=${SOLIS_NVLINK_EXPECTED_GPUS:-2}
EXPECTED_LINKS_PER_GPU=${SOLIS_NVLINK_EXPECTED_LINKS_PER_GPU:-2}

die() {
    echo "NVLINK_GATE=FAIL: $*" >&2
    exit 1
}

command -v nvidia-smi >/dev/null 2>&1 ||
    die "nvidia-smi not found"

mapfile -t GPU_LINES < <(
    nvidia-smi \
        --query-gpu=index,pci.bus_id,name \
        --format=csv,noheader,nounits
)

(( ${#GPU_LINES[@]} == EXPECTED_GPUS )) ||
    die "expected ${EXPECTED_GPUS} GPUs, found ${#GPU_LINES[@]}"

echo "=== GPU MAP ==="
printf '%s\n' "${GPU_LINES[@]}"

echo
echo "=== NVLINK STATUS ==="

STATUS=$(nvidia-smi nvlink -s)
printf '%s\n' "$STATUS"

for ((gpu=0; gpu<EXPECTED_GPUS; gpu++)); do
    for ((link=0; link<EXPECTED_LINKS_PER_GPU; link++)); do
        value=$(
            printf '%s\n' "$STATUS" |
            awk -v gpu="$gpu" -v link="$link" '
                $1 == "GPU" && $2 ~ ("^" gpu ":") {
                    in_gpu = 1
                    next
                }
                $1 == "GPU" {
                    in_gpu = 0
                }
                in_gpu && $1 == "Link" && $2 ~ ("^" link ":") {
                    sub(/^.*Link [0-9]+:[[:space:]]*/, "")
                    print
                    exit
                }
            '
        )

        [[ -n "$value" ]] ||
            die "GPU${gpu} Link${link} missing"

        [[ "$value" != *"<inactive>"* ]] ||
            die "GPU${gpu} Link${link} inactive"

        [[ "$value" =~ GB/s ]] ||
            die "GPU${gpu} Link${link} unexpected state: $value"
    done
done

echo
echo "=== REMOTE PCI MAP ==="

REMOTE=$(nvidia-smi nvlink -p)
printf '%s\n' "$REMOTE"

for ((gpu=0; gpu<EXPECTED_GPUS; gpu++)); do
    for ((link=0; link<EXPECTED_LINKS_PER_GPU; link++)); do
        if ! printf '%s\n' "$REMOTE" |
            awk -v gpu="$gpu" -v link="$link" '
                $1 == "GPU" && $2 ~ ("^" gpu ":") {
                    in_gpu = 1
                    next
                }
                $1 == "GPU" {
                    in_gpu = 0
                }
                in_gpu &&
                $1 == "Link" &&
                $2 ~ ("^" link ":") &&
                $3 ~ /^[0-9A-Fa-f]{8}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$/ {
                    found = 1
                }
                END {
                    exit(found ? 0 : 1)
                }
            '
        then
            die "GPU${gpu} Link${link} has no remote PCI endpoint"
        fi
    done
done

echo
echo "=== ERROR COUNTERS ==="

ERRORS=$(nvidia-smi nvlink -e || true)
printf '%s\n' "$ERRORS"

NONZERO=$(
    printf '%s\n' "$ERRORS" |
    awk '
        /Replay Errors:|Recovery Errors:|CRC Errors:/ {
            value = $NF + 0
            if (value != 0)
                bad++
        }
        END {
            print bad + 0
        }
    '
)

if (( NONZERO > 0 )); then
    echo "NVLINK_GATE_WARNING=nonzero_error_counters:${NONZERO}" >&2
fi

echo
echo "NVLINK_GATE=PASS"
