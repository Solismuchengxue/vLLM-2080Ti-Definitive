# Solis 双 RTX 2080 Ti / Qwen3.8 27B / 262K 运行封板

状态：**HARDWARE-VERIFIED FOR THE EXECUTED SEQUENCES**

日期：2026-09-27

本文记录 HP Z6 G4 + WSL2 + 双 RTX 2080 Ti 22 GB + NVLink 上，
Solis 一键启动包装器、固定 180 W / 180 W AI 功耗门禁和
Qwen3.8-27B 262K vLLM 路线的实机验证结果。

它不是通用硬件承诺，也不改变 `Solis_GPU_Governor`
已封板的手动功耗策略历史。

## 固定硬件身份

| GPU | UUID | PCI Bus | 本路线目标 PL |
| --- | --- | --- | ---: |
| GPU0 | `GPU-d21daf2a-f8cc-c6d5-cb9d-1422779319f5` | `00000000:21:00.0` | 180 W |
| GPU1 | `GPU-2d42853e-1ddb-ac75-9e87-6ff267fb9533` | `00000000:2D:00.0` | 180 W |

本次实机查询观察到两卡：

- `power.default_limit = 250 W`
- `power.min_limit = 100 W`
- `power.max_limit = 280 W`

180 W 是本 Solis AI runtime 路线的固定目标，不是 NVIDIA 默认值，
也不声明为其他硬件的推荐值。

## Canonical 文件

- `tools/solis-runtime/solis`
- `tools/solis-runtime/apply-power-cap-180.sh`
- `tools/windows/Install-SolisAiPowerTask.ps1`
- `tools/solis-preflight/check_nvlink.sh`
- `tools/windows/Test-SolisHostPreflight.ps1`
- `launcher.sh`

本机便捷入口：

~~~text
~/bin/solis
    -> tools/solis-runtime/solis

~/bin/solis-power-cap
    -> tools/solis-runtime/apply-power-cap-180.sh
~~~

## 启动顺序

服务未运行时：

~~~text
Windows host commit/pagefile preflight
        ↓
NVLink 双 Link / PCI map / error-counter gate
        ↓
Solis AI GPU power cap 180 W + 180 W
        ↓
vm.overcommit_memory 临时设为 1
        ↓
vLLM 262K route
        ↓
health + smoke
        ↓
SOLIS_START=PASS
        ↓
恢复原 vm.overcommit_memory
~~~

服务已经运行时：

~~~text
HTTP health=200
        ↓
NVLink gate
        ↓
重新验证并按需施加 180 W + 180 W
        ↓
SOLIS_STATUS=ALREADY_RUNNING
~~~

已运行路径不重新启动 vLLM。

## 功耗门禁

`apply-power-cap-180.sh`：

1. 通过 Windows `nvidia-smi.exe` 查询完整 GPU inventory。
2. 要求恰好出现两张预期 UUID。
3. 验证每张卡的固定 PCI Bus。
4. 查询实时 `power.limit/default/min/max`。
5. 验证 180 W 位于每张卡实时合法范围内。
6. 若已经是 180/180，则幂等成功，不发写命令。
7. 若存在偏差，通过 Windows `schtasks.exe` 按需运行
   `\Solis-AI-Power-180W`。
8. 最多轮询约 10 秒，最终两张卡都必须 readback 为 180 W。
9. UUID、Bus、范围、任务触发或 readback 任一失败均 fail-closed。

Linux `sudo` 不承担 Windows GPU 管理权限。

## Windows elevated task

`Install-SolisAiPowerTask.ps1` 注册按需任务：

~~~text
\Solis-AI-Power-180W
~~~

任务以当前 Windows 用户的 Highest 权限运行两个固定 action：

~~~text
nvidia-smi.exe -i GPU-d21daf2a-f8cc-c6d5-cb9d-1422779319f5 -pl 180
nvidia-smi.exe -i GPU-2d42853e-1ddb-ac75-9e87-6ff267fb9533 -pl 180
~~~

任务没有接受自定义 wattage、GPU index 或任意 executable 的接口。

正常 `solis` 功耗路径只调用 `schtasks.exe` 和 `nvidia-smi.exe`。
Windows host commit/pagefile preflight 仍单独依赖 PowerShell 7。

## vLLM 固定路线

本轮实机封板配置：

~~~text
Target:        Qwen3.8-27B-NVFP4
Draft:         Qwen3.8-27B-DFlash2
GPU:           2 x RTX 2080 Ti 22 GB
NVLink:        Link0 + Link1, 25.781 GB/s each
TP / PP:       TP2 / PP1
Context:       262144
Quantization:  compressed-tensors / W4A16
Target KV:     FP8
Draft KV:      FP16
Spec decode:   DFlash2 K=7
GPU util:      0.938
Max sequences: 1
Vision:        enabled
Image limit:   64
Prefix cache:  enabled
Tool calling:  auto / qwen3_xml
Reasoning:     qwen3 parser
Custom AR:     off
~~~

长期约束继续保持：

- 不使用 `expandable_segments`。
- 不使用 `cudaMallocAsync`。
- 模型存放在 WSL ext4。
- `VLLM_WSL2_ENABLE_PIN_MEMORY=1`。
- `CUSTOM_ALL_REDUCE_MODE=off`。
- 不降低 262144 context、DFlash2 K=7、FP8 target KV
  或 Vision/image limit 来规避问题。

## 非交互 launcher

`launcher.sh` 的 `is_tty()` 显式尊重：

~~~text
NON_INTERACTIVE=1
~~~

Solis 因此不会进入交互菜单，也不会运行或询问启动性能 benchmark；
startup health 和 smoke test 仍保留。

## 实机验证 A：冷启动 + 自动功耗

初始条件：

~~~text
vLLM: STOPPED
GPU0 power.limit = 170 W
GPU1 power.limit = 170 W
~~~

仅从 Ubuntu 执行：

~~~text
solis
~~~

观察结果：

~~~text
HOST_PREFLIGHT=PASS
NVLINK_GATE=PASS

Applying fixed Solis AI power cap: 180W + 180W ...
GPU0 readback = 180 W
GPU1 readback = 180 W
GPU_POWER_CAP=PASS

Health check: OK
Smoke response: OK
START OK
HEALTH=HTTP_200
SOLIS_START=PASS
~~~

本次启动没有出现：

~~~text
Startup benchmark warm-up
Run 3x 4K/128 + 1x 32K/512 performance test now? [y/N]
~~~

最终 `vm.overcommit_memory` 恢复为启动前值。

分类：

**HARDWARE-VERIFIED FOR 170/170 → SOLIS → 180/180 → 262K START OK。**

## 实机验证 B：运行中功耗漂移修正

初始条件：

~~~text
HEALTH_BEFORE=HTTP_200
PID_BEFORE=10676

GPU0 power.limit = 170 W
GPU1 power.limit = 180 W
~~~

再次执行：

~~~text
solis
~~~

观察：

~~~text
Service already running.
HEALTH=HTTP_200
NVLINK_GATE=PASS

Applying fixed Solis AI power cap: 180W + 180W ...
GPU_POWER_CAP=PASS

SOLIS_STATUS=ALREADY_RUNNING
~~~

执行后：

~~~text
HEALTH_AFTER=HTTP_200
PID_AFTER=10676
PID_STABILITY=PASS

GPU0 power.limit = 180 W
GPU1 power.limit = 180 W
~~~

分类：

**HARDWARE-VERIFIED FOR IN-PLACE POWER-CAP CORRECTION WITHOUT VLLM RESTART。**

## 已验证的 supporting facts

- Windows Scheduled Task 首次真实执行返回 `LastTaskResult=0`。
- Windows 管理员路径真实完成 170 W → 180 W 双卡写入与 readback。
- Ubuntu 通过 `schtasks.exe /Run` 可触发同一 elevated task。
- Windows task installer 通过 PowerShell AST parser：
  `POWERSHELL_SYNTAX=PASS / PARSER_RC=0`。
- `launcher.sh`、`solis` 与 power helper 均通过 Bash syntax check。
- NVLink 两卡 Link 0 / Link 1 均报告 25.781 GB/s，
  验证过程中 error counters 为 0。

## 边界

本证据只覆盖上述真实执行序列。

它不证明：

- 任意 GPU 型号或任意 UUID/Bus 布局可直接使用。
- 任意 Windows/NVIDIA driver 版本都有相同 PL 行为。
- 180 W 会跨 Windows reboot 持久化。
- Scheduled Task failure、Windows interop failure
  或所有异常路径都已经过真实硬件故障注入。
- `Solis_GPU_Governor` 的自动策略已经采用 180/180。
- Power cap 能提供计算优先级、显存隔离
  或防止其他管理员修改 PL。

Windows reboot 后若 NVIDIA 驱动恢复 default PL，
下一次 `solis` 会重新验证并按需施加 180/180。
