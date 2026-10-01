# Z6 Production Baseline

## 1. Purpose

This document records the validated production baseline of the HP Z6 G4 inference
node for recovery, upgrades, and troubleshooting. It is a reference document,
not a runtime configuration entry point, and does not replace `launcher.sh`.

The production source of truth is the repository inside Ubuntu-26.04, for example
`/home/<user>/vLLM-2080Ti-Definitive`. A Windows working copy is not the production
runtime source of truth.

This deployment uses vLLM 2080 Ti Definitive Edition, based on upstream vLLM.
Project author: [github.com/weicj](https://github.com/weicj).

## 2. Hardware

| Component | Validated baseline |
| --- | --- |
| Node | HP Z6 G4 |
| GPUs | NVIDIA RTX 2080 Ti 22GB x2 |
| GPU power limits | 180W / 180W |
| NVLink | Enabled |
| NVLink links | 4 reported links across both GPUs |
| Reported link rate | 25.781 GB/s/link |
| Replay errors | 0 |
| Recovery errors | 0 |
| CRC errors | 0 |

The link rate and error counters are verified `nvidia-smi` observations,
not an application throughput benchmark.

## 3. Host Environment

| Component | Validated baseline |
| --- | --- |
| Windows | 10.0.26200.9457 |
| WSL | 3.0.1.0 |
| Kernel | 6.18.40.1-microsoft-standard-WSL2 |
| Distribution | Ubuntu-26.04 |
| systemd | Enabled |

The kernel was rechecked with `uname -r` after the WSL upgrade.
`6.18.33.2-microsoft-standard-WSL2` was the pre-upgrade kernel, not the current
WSL 3.0.1 production kernel.

## 4. Solis Runtime

| Item | Validated baseline |
| --- | --- |
| Repository | vLLM-2080Ti-Definitive |
| Production branch | prod/wsl-stable-minimal |
| Production commit | e6491a7e935932f879e2ed570b4e1db347656eef |
| Working tree at runtime validation | Clean |

The commit identifies the runtime baseline before this documentation addition.
Z6-local DSH integration has been retired from this baseline.

## 5. vLLM Runtime

| Item | Validated baseline |
| --- | --- |
| Runtime | vllm-def-cu130 |
| Model | Qwen3.8-27B-NVFP4 |
| Draft model | Qwen3.8-27B-DFlash2 |
| Quantization | compressed-tensors |
| W/A | W4A16 |
| GPU devices | 0,1 |
| Parallel layout | TP2 x PP1 |
| KV precision | FP8 |
| Context tokens | 262144 |
| Speculative decoding | dflash2/7 |

These values describe the validated route. This document does not set or modify
model parameters, profiles, environment files, or service configuration.

## 6. Verified Health State

Validation date: **2026-10-01**.

```text
HOST_PREFLIGHT=PASS
NVLINK_GATE=PASS
GPU_POWER_CAP=PASS
HEALTH=200
models_api=200
chat_smoke=PASS
```

The model API returned `Qwen3.8-27B-NVFP4` with `max_model_len=262144`.
A minimal chat request returned HTTP 200, content `OK`, and finish reason `stop`.
The launcher reported `START OK` and `Smoke response: OK`.
The temporary startup change to `vm.overcommit_memory=1` was restored to `0`.

These results are a dated validation snapshot, not a guarantee of future uptime.

## 7. Operations

Run the existing manager from the production repository in an interactive
Ubuntu-26.04 terminal:

```bash
cd /home/<user>/vLLM-2080Ti-Definitive
./launcher.sh
```

- **Start:** choose **8. Start service** with the existing
  `Qwen3.8-27B-NVFP4` configuration and confirm the start.
- **Stop:** choose **9. Stop service**, select
  `vllm-Qwen3.8-27B-NVFP4`, and confirm the stop.

Use the manager's service controls for normal maintenance. Do not substitute
manually assembled vLLM arguments for the existing validated route.

Keep an Ubuntu-26.04 interactive terminal open during normal production use.
Under this node's observed operating arrangement, closing the last WSL terminal
allows the distribution to exit after approximately one minute.

## 8. Architecture

Z6 inference path:

```text
Z6
 |
 +-- WSL Ubuntu-26.04
       |
       +-- Solis
             |
             +-- vLLM :8000
                    |
                    +-- Qwen3.8-27B-NVFP4
```

fnOS request path:

```text
fnOS
 |
 +-- DSH :28000
       |
       +-- solis-z6g4
             |
             +-- Z6 :8000
```

DSH is on the fnOS side of this topology. Z6 serves the vLLM API on port 8000;
the former Z6-local DSH integration is retired. The fnOS topology is deployment
context supplied for this baseline; the health results above validate the Z6 API
and runtime.

## 9. Known Issues

With the previous WSL version, a systemd-enabled sibling distribution shutting
down could clear the VM-global `binfmt_misc` registry. The `WSLInterop` handler
then disappeared from a still-running distribution, and Windows executables
such as `cmd.exe` and `pwsh.exe` failed with `Exec format error` / exit 126.

This issue was resolved on Z6 by upgrading to **WSL 3.0.1**. The upstream fix is
[Microsoft WSL commit f67086e3d5d0b69094b45acc9c482e4a5132ed8d](https://github.com/microsoft/WSL/commit/f67086e3d5d0b69094b45acc9c482e4a5132ed8d),
`fix(init): protect binfmt_misc from cross-distro wipe at shutdown (#40621)`.

After the upgrade and WSL VM restart, the automatically registered handler was
enabled, used interpreter `/init`, and had flags `PF`. Ubuntu-24.04 was started
and allowed to stop while Ubuntu-26.04 remained running. The handler remained
present, and both `cmd.exe` and PowerShell 7 interop tests passed.

The production baseline relies on the official WSL fix. Temporary handler
re-registration is not a long-term operating procedure for this baseline.
