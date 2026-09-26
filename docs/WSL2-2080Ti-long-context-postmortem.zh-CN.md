# WSL2 + 2× RTX 2080 Ti 22 GB 长上下文踩坑与故障复盘

本文记录 `vLLM-2080Ti-Definitive` 在 WSL2、双 RTX 2080 Ti 22 GB + NVLink、
Qwen3.8-27B-NVFP4 + DFlash2 K=7、262144 context 路线上的实际故障、误判点、
最终修复和启动前检查顺序。

这不是通用 CUDA 故障清单。文中的结论只覆盖本次已经验证的故障链；尤其不要把所有
`DXG create_allocation -75` 都直接解释为 host commit 耗尽，也不要把一次 NVLink
故障直接推导成 bridge 本体永久损坏。

## 稳定恢复点

- Base: `2d63e2e322b7488776d1fb822f3556dbd7334116` (`v0.2.2`)
- Runtime fix: `ba72a6c82fd5edfdb9cff8a3a49499a75e72b822`
- Branch: `fix/wsl-long-context-tp2`
- Hardware: 2× RTX 2080 Ti 22 GB + NVLink
- Target: Qwen3.8-27B-NVFP4
- Draft: Qwen3.8-27B-DFlash2
- TP/PP: TP2 × PP1
- Context: 262144
- Target KV: FP8
- Draft KV: FP16
- DFlash2: K=7
- Vision: enabled
- Image limit: 64
- `gpu-util`: 0.938

最终冷启动验证：

```text
START OK
Smoke OK
GPU KV cache size: 263782 tokens
/health: HTTP 200
NVLINK_GATE=PASS
```

双卡两条 NVLink 均为 25.781 GB/s，Replay / Recovery / CRC error counter 均为 0。

## 1. DXG create_allocation -75 不等于普通显存 OOM

### 现象

WSL guest 中出现：

```text
dxgvmb_send_create_allocation: send_create_allocation failed ffffffb5
dxgkio_create_allocation: Ioctl failed: -75
```

失败时显卡仍可能有数 GiB 空闲显存，因此单看 `nvidia-smi` 会误以为“显存明明够”。

本次最关键的 Windows host 证据来自 Event 2004：

```text
SystemCommitLimit   ≈ 56.855 GiB
SystemCommitCharge  ≈ 56.782 GiB
Commit headroom     ≈ 73.8 MiB
vmmemWSL commit     ≈ 39.70 GiB
```

与此同时，WSL guest 内仍可看到较多 `MemAvailable`，swap 也没有耗尽。

### 结论

对于本次启动故障，真正的瓶颈是 Windows host commit，而不是普通 VRAM exhaustion。
guest 内存与 swap 指标不能替代 Windows commit/pagefile 检查。

这不意味着今后所有 `create_allocation -75` 都必然是同一个原因。正确做法是先查
host commit，再决定是否继续看 allocator、VRAM 或 DXG。

### 修复

Windows pagefile 从较小固定值扩大到：

```text
D:\pagefile.sys
InitialSize = 81920 MiB
MaximumSize = 81920 MiB
```

重启后：

```text
Commit Limit ≈ 111.71 GiB
Headroom     ≈ 53.48 GiB
HOST_PREFLIGHT=PASS
```

同一最终 vLLM 配置随后成功启动。

正式检查脚本：

```text
tools/windows/Test-SolisHostPreflight.ps1
```

它检查 live/configured pagefile、Windows commit headroom、物理内存，并把历史 Event
2004 作为 warning 显示。

该脚本应在 Windows PowerShell 中执行；不需要为了它在 WSL 中额外安装 `pwsh`。

## 2. 262K 请求导致整机失联：另一条 NVLink/TDR 故障链

扩大 pagefile 并解决启动阶段问题后，第一次近 262K 请求仍出现：

- RDP 断开；
- 本地显示无响应；
- GPU 风扇升高；
- 最终需要强制关机。

这次没有新的 Windows Event 2004，也没有新的 WSL kernel panic。

Windows NVIDIA 日志首先出现：

```text
NVLink: fatal error detected on link 1
```

随后才出现：

```text
UCodeReset TDR occurred
GpuRcReset TDR occurred
Resetting TDR occurred
LiveKernelEvent 141
```

重启后 `nvidia-smi nvlink -s` 显示一条链路持续 inactive：

```text
Link 0: 25.781 GB/s
Link 1: <inactive>
```

完整冷关机没有恢复 Link 1。物理重新拔插 NVLink bridge 后，两卡两条 link 全部恢复：

```text
GPU0 Link0/Link1: 25.781 GB/s
GPU1 Link0/Link1: 25.781 GB/s
Replay/Recovery/CRC: 0
```

随后近极限长上下文请求成功，服务保持健康。

### 结论

本次 262K 整机失联与 NVLink 物理路径/接触/机械状态高度相关，并触发后续 TDR reset。
现有证据不足以证明 bridge 本体永久损坏，因此不要把结论写成“NVLink bridge 坏了”。

### 不要用 topo -m 作为本机 health gate

这台机器历史上即使 SLI/P2P/NVLink 正常，`nvidia-smi topo -m` 也可能失败，因此它
被排除在正式 health gate 之外。

正式 gate 使用：

```text
nvidia-smi nvlink -s
nvidia-smi nvlink -p
nvidia-smi nvlink -e
```

仓库脚本：

```text
tools/solis-preflight/check_nvlink.sh
```

必须看到：

```text
NVLINK_GATE=PASS
```

若出现 NVLink fatal、TDR 或 inactive link，应先停止 TP2 workload，检查并重新安装
bridge，再做长上下文负载。不要先去重复 CUDA/NCCL/P2P baseline。

## 3. 模型权重不要放在 /mnt/f 热路径

曾直接从 Windows drvfs 路径加载大模型：

```text
/mnt/f/...
```

结果出现过 SIGBUS，模型加载时间约 231 秒。

迁移到 WSL ext4：

```text
/home/smile/models/...
```

同类加载下降到约 17.85 秒，并消除了该条路径上的异常。

因此正式服务中的 target/draft 权重都放在 WSL ext4。Windows 盘可用于下载、归档和
诊断材料，但不要作为模型权重热路径。

## 4. 被否决的 allocator 方案

### expandable_segments

本 WSL/DXG 路线不使用 `expandable_segments`。它不是当前稳定设计的一部分，也不要
为了“减少碎片”重新打开。

### cudaMallocAsync

`cudaMallocAsync` 在本路线实际破坏过 Marlin repack，因此禁用。

### 旧 5 GiB live tensor arena

早期实验曾在模型加载前创建一个约 5 GiB 的 live CUDA tensor。它确实能让那次大块
allocation 提前成功，但 tensor 一直占 active memory，后续 target model 仍可能在还有
约 5 GiB free 时遇到 DXG allocation failure。

因此 live arena 路线永久淘汰。

## 5. 正式方案：Early KV Lending Pool

最终设计位于：

```text
vllm/v1/worker/early_kv_arena.py
```

核心是：

```python
torch.cuda.MemPool(use_on_oom=True)
```

流程：

```text
CUDA/NCCL initialization
        ↓
create private MemPool
        ↓
allocate + touch 5 GiB primer
        ↓
delete primer
        ↓
backing remains cached in private pool
        ↓
model load can borrow via use_on_oom
        ↓
final KV backing allocated from same pool
        ↓
strict check: num_device_alloc delta == 0
```

正式环境变量：

```bash
export VLLM_WSL_EARLY_KV_GIB=5.0
export VLLM_WSL_EARLY_KV_STRICT=1
export VLLM_WSL_DXG_KV_SLAB_MB=2048
```

`LENDING_POOL_*` marker、`num_device_alloc()` 和
`verify_no_device_alloc()` 属于正式 invariant/诊断边界，应保留。

## 6. max_split_size_mb=20 在 WSL/DXG 下反而增加风险

原有 scoped allocator policy 会把 allocation 切得更碎，从而增加 `cudaMalloc` /
DXG create-allocation transaction 数量。

在 WSL/DXG 已经出现 create-allocation instability 的环境里，这种策略会放大风险。
因此当前 patch 在 WSL 中跳过：

```text
_scoped_allocator_max_split(max_split_size_mb=20)
```

保留 PyTorch 默认 allocator policy。

## 7. KV backing 使用 WSL/DXG slab allocation

`vllm/v1/worker/utils.py` 中保留 WSL/DXG KV slab allocator。最终 KV backing 被拆成
较大的有限数量 slab，而不是重新引入高频小 allocation。

本轮最终计划中每个 rank 使用 3 个 slab，总计约 5 GiB，并通过 Early KV pool 验证最终
KV backing 不产生新的 device allocation。

## 8. 262K RoPE cache 不要无脑直接在 GPU 上构建

长上下文下直接在 GPU 创建完整 cos/sin cache 会制造额外的大块 allocation。

当前 WSL 路线对长序列采用：

```text
sequence length >= 131072
        ↓
build cos/sin on CPU
        ↓
convert to low precision
        ↓
move compact cache to GPU
```

实现位于：

```text
vllm/model_executor/layers/rotary_embedding/base.py
```

## 9. Qwen3.5 / DFlash2 必须保留的约束

DFlash2 config 中必须保留：

```json
"draft_vocab_size": 4096
```

否则可能再次触发临时 full-vocab `lm_head` allocation。

同时保留 Qwen3.5 MTP embed/lm_head sharing patch。不要让 draft 模型重新拥有独立的
完整 embedding/lm_head 临时分配。

本路线最终约束：

```text
MAX_MODEL_LEN = 262144
Target KV     = FP8
Draft KV      = FP16
DFlash2 K     = 7
Vision        = enabled
Image limit   = 64
MAX_NUM_SEQS  = 1
```

解决稳定性问题时，不要通过降低 context、K、Vision 或 image limit 来绕过根因。

## 10. 临时 blackbox marker 与正式 marker 必须分开

故障定位期间曾临时加入：

```text
WEIGHT_READY_*
WEIGHT_CONSUMED_*
TARGET_LOAD_*
DFLASH_LOAD_*
MODEL_RUNNER_LOAD_ENTER
EMBED_*
```

这些 marker 用于区分 safetensors 读取、consumer、GPU copy 等边界。根因定位完成后
已全部从正式 source diff 中清除。

正式保留的是 Early KV 自身的 `LENDING_POOL_*` 和 allocator invariant 检查。

原则：临时事故 tracing 可以帮助定位，但不能和最终修复一起长期沉积在 loader/model
代码中。

## 11. 交互式 shell 中不要直接执行带 exit 1 的临时校验脚本

曾把 fail-fast 片段直接粘到长期使用的 Ubuntu 交互 shell：

```bash
if failed; then
    exit 1
fi
```

校验失败会直接退出整个 Ubuntu shell 窗口。

临时检查应放进子 shell：

```bash
(
    # checks
    exit 1
)
RC=$?
```

这样 fail-fast 只终止子 shell，不会杀掉主会话。

## 12. Git 工作流踩坑

本地 checkout 最初位于 tag/grafted 基线：

```text
2d63e2e
tag: v0.2.2
```

第一次正式 commit 后处于 detached HEAD。正确处理是先锚定本地分支：

```bash
git switch -c fix/wsl-long-context-tp2
```

WSL 中没有预装 `gh`，因此不要假设 `gh api user` 可用。

GitHub HTTPS Git 操作也不支持账号密码。最终使用 Windows 已有 SSH key，复制到 WSL
并通过：

```bash
ssh -T git@github.com
```

验证。

最终 remote 语义：

```text
origin   -> Solismuchengxue/vLLM-2080Ti-Definitive
upstream -> weicj/vLLM-2080Ti-Definitive
```

并把 upstream push URL 设置为 `DISABLED`，避免误推原作者仓库。

## 13. 正式启动前固定 SOP

以后不要直接“启动试试看”。

### Windows host

运行：

```powershell
tools/windows/Test-SolisHostPreflight.ps1
```

要求：

```text
HOST_PREFLIGHT=PASS
```

### WSL NVLink

运行：

```bash
./tools/solis-preflight/check_nvlink.sh
```

要求：

```text
NVLINK_GATE=PASS
```

### 然后启动 vLLM

最终服务必须至少满足：

```text
START OK
Smoke OK
/health = HTTP 200
```

## 14. 故障决策树

### 再次出现 DXG create_allocation -75

优先检查：

1. Windows host commit charge / limit；
2. pagefile live size 与配置；
3. Event 2004；
4. 然后才继续看 VRAM / allocator / DXG。

不要只凭 `nvidia-smi` free VRAM 下结论。

### 再次出现 NVLink fatal / TDR / inactive link

优先：

1. 停止 TP2 workload；
2. `nvidia-smi nvlink -s/-p/-e`；
3. 检查 bridge 安装和接触；
4. 必要时断电后重新安装 bridge；
5. gate 通过后再启动长上下文服务。

### 再次出现模型加载异常或 SIGBUS

先确认 target/draft 是否在 WSL ext4，而不是 `/mnt/<drive>`。

## 15. 本轮最终验证记录

修复 commit：

```text
ba72a6c82fd5edfdb9cff8a3a49499a75e72b822
fix(wsl): stabilize long-context TP2 allocation on 2080 Ti
```

冷启动结果：

```text
Startup complete: 172s
Health check: OK
START OK
Smoke: OK
GPU KV cache: 263782 total tokens
```

冷启动后的 NVLink gate：

```text
GPU0 Link0: 25.781 GB/s
GPU0 Link1: 25.781 GB/s
GPU1 Link0: 25.781 GB/s
GPU1 Link1: 25.781 GB/s

Replay Errors:   0
Recovery Errors: 0
CRC Errors:      0

NVLINK_GATE=PASS
```

此状态作为当前 WSL2 双 2080 Ti 262K 路线的稳定恢复点。后续优化应另开 commit/branch，
不要把新的实验性 allocator 或 tracing 直接混入该恢复点。
