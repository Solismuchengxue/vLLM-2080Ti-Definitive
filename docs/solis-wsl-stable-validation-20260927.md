# Solis WSL Stable Validation — 2026-09-27

## Purpose

This document records validation of the minimal Solis production runtime on
official stable WSL using the upstream `v0.2.2-post2` vLLM core.

The validated production path contains:

- no local modifications under `vllm/**`;
- no local modification to upstream `launcher.sh`;
- only Solis perimeter tooling outside the upstream runtime core.

The result applies to the specific environment and workloads recorded below.
It does not claim that historical WSL workarounds were unnecessary under every
older WSL, driver, host-memory, hardware, or runtime state.

## Validated source state

Production candidate branch:

~~~text
prod/wsl-stable-minimal
~~~

Validation originated from:

~~~text
audit/minimal-wsl-stable
fce6d0e9a18e33fd6d8f250ede10a6136d1ba74e
~~~

Upstream baseline:

~~~text
tag:    v0.2.2-post2
commit: 8185fc33ba404406d51678eb0f0b5d071aaf1e4f
~~~

Core integrity command:

~~~bash
git diff --exit-code v0.2.2-post2 -- vllm launcher.sh
~~~

Result:

~~~text
CORE_DIFF_RC=0
~~~

Therefore the validated runtime contains no local production modification to
`vllm/**` or `launcher.sh`.

The only source delta against `v0.2.2-post2` before adding this document was:

~~~text
tools/solis-preflight/check_nvlink.sh
tools/solis-runtime/apply-power-cap-180.sh
tools/solis-runtime/solis
tools/windows/Install-SolisAiPowerTask.ps1
tools/windows/Test-SolisHostPreflight.ps1
~~~

Observed delta:

~~~text
5 files changed, 654 insertions(+)
~~~

## Host and WSL environment

~~~text
Windows:        10.0.26200.9457
WSL:            2.7.14.0
WSL kernel:     6.18.33.2-2
Distribution:   Ubuntu-26.04

GPU0:           NVIDIA GeForce RTX 2080 Ti 22 GB
GPU1:           NVIDIA GeForce RTX 2080 Ti 22 GB
Parallelism:    TP2 x PP1

NVLink:
  GPU0 Link0:   25.781 GB/s
  GPU0 Link1:   25.781 GB/s
  GPU1 Link0:   25.781 GB/s
  GPU1 Link1:   25.781 GB/s

GPU power cap:  180 W per GPU
~~~

Windows host preflight immediately before the final validation run:

~~~text
Pagefile:             D:\pagefile.sys
Initial size:         81920 MiB
Maximum size:         81920 MiB

System commit:        18.11 GiB
Commit limit:         111.71 GiB
Commit headroom:      93.60 GiB

Physical RAM:         31.71 GiB
Recent Event 2004:    none in previous 24 h
HOST_PREFLIGHT=PASS
~~~

NVLink preflight:

~~~text
Replay Errors:        0
Recovery Errors:      0
CRC Errors:           0
NVLINK_GATE=PASS
~~~

## Runtime configuration

~~~text
Target model:           Qwen3.8-27B-NVFP4
Draft model:            Qwen3.8-27B-DFlash2
Quantization:           compressed-tensors / W4A16

Tensor parallelism:     TP2
Pipeline parallelism:   PP1

Target KV precision:    fp8
Context length:         262144
Max sequences:          1
Max batched tokens:     2048

DFlash2 K:              7
Prefix cache:           enabled
Custom all-reduce:      off

Message type:           text+image
Reasoning parser:       qwen3
Tool-call parser:       qwen3_xml
Strict tool calling:    enabled
Image limit:            64 per prompt

GPU memory util:        0.938
~~~

Startup result:

~~~text
HEALTH=HTTP_200
SOLIS_START=PASS
~~~

Temporary startup overcommit was correctly restored:

~~~text
vm.overcommit_memory=0
~~~

## Cold 260K inference

The running server's `/tokenize` endpoint was used to determine the exact
server-side prompt size before inference.

~~~text
TOKENIZE_HTTP_STATUS=200
SERVER_PROMPT_TOKENS=260000
SERVER_MAX_MODEL_LEN=262144
HEADROOM_BEFORE_OUTPUT=2144
TOKENIZE_GATE=PASS
~~~

The exact same message was then submitted to `/v1/chat/completions`.

~~~text
HTTP_STATUS=200
ELAPSED_SEC=1286.58

SERVER_PROMPT_TOKENS=260000
SERVER_COMPLETION_TOKENS=18
SERVER_TOTAL_TOKENS=260018

FINISH_REASON=stop
CONTENT='SOLIS_NEAR_262K_END_7F3C91'

NEAR_262K_REQUEST=PASS
END_MARKER=PASS
~~~

Post-request state:

~~~text
HEALTH_AFTER=HTTP_200

WSL memory:
  total:       15 GiB
  used:        8.9 GiB
  free:        6.2 GiB
  available:   6.5 GiB

WSL swap:
  total:       6.0 GiB
  used:        15 MiB

GPU0 memory:   21799 / 22528 MiB
GPU1 memory:   21799 / 22528 MiB

GPU0 PL:       180 W
GPU1 PL:       180 W

vm.overcommit_memory=0
~~~

All NVLink Replay, Recovery, and CRC counters remained zero.

## 260K prefix-cache and DFlash2 replay

A second request retained the approximately 260K-token prefix and changed only
the final probe marker from:

~~~text
SOLIS_NEAR_262K_END_7F3C91
~~~

to:

~~~text
SOLIS_NEAR_262K_END_7F3C92
~~~

Result:

~~~text
HTTP_STATUS=200
ELAPSED_SEC=18.90

SERVER_PROMPT_TOKENS=260000
CACHED_TOKENS=257088
CREATED_CACHE_TOKENS=0

SERVER_COMPLETION_TOKENS=18
SERVER_TOTAL_TOKENS=260018

FINISH_REASON=stop
CONTENT='SOLIS_NEAR_262K_END_7F3C92'

PREFIX_CACHE_REUSE=PASS
DFLASH2_REPLAY_CORRECTNESS=PASS
END_MARKER_B=PASS
~~~

The changed tail marker was returned correctly while 257088 prompt tokens were
reused from cache.

Post-request health:

~~~text
HEALTH_AFTER_REPLAY=HTTP_200
~~~

All NVLink Replay, Recovery, and CRC counters remained zero.

## Reasoning validation

### Reasoning disabled

Request setting:

~~~text
enable_thinking=false
~~~

Result:

~~~text
HTTP_STATUS=200
CONTENT='SOLIS_REASONING_OFF_7F3C93'
REASONING=''
FINISH_REASON=stop
REASONING_OFF=PASS
~~~

### Reasoning enabled

Request setting:

~~~text
enable_thinking=true
~~~

Result:

~~~text
HTTP_STATUS=200
CONTENT='\n\nSOLIS_REASONING_HIGH_7F3C93'
REASONING_LEN=423
FINISH_REASON=stop
REASONING_HIGH=PASS
~~~

The reasoning payload was returned in:

~~~text
message.reasoning
~~~

The final content was correct after whitespace normalization.

## Tool-calling validation

The runtime was asked to call exactly one function:

~~~text
report_probe
~~~

Expected argument:

~~~json
{"probe":"SOLIS_TOOL_7F3C93"}
~~~

Observed result:

~~~text
HTTP_STATUS=200
FINISH_REASON=tool_calls

tool name=report_probe
probe=SOLIS_TOOL_7F3C93

TOOL_CALLING=PASS
~~~

Post-functional health:

~~~text
HEALTH_AFTER_FUNCTIONAL=HTTP_200
~~~

All NVLink Replay, Recovery, and CRC counters remained zero.

## Vision validation

### Single-image grounding

A locally generated 256 x 256 PNG contained four color quadrants:

~~~text
top-left:      red
top-right:     green
bottom-left:   blue
bottom-right:  yellow
~~~

Observed result:

~~~text
HTTP_STATUS=200
CONTENT='TOPLEFT=RED;BOTTOMRIGHT=YELLOW'
REASONING=''
FINISH_REASON=stop

prompt_tokens=109
completion_tokens=10
multimodal image tokens=64

VISION_SINGLE_IMAGE=PASS
VISION_COLOR_GROUNDING=PASS
VISION_GATE=PASS
~~~

Post-request health:

~~~text
HEALTH_AFTER_VISION=HTTP_200
~~~

All NVLink Replay, Recovery, and CRC counters remained zero.

### 64-image configured boundary

Exactly 64 images:

~~~text
HTTP_STATUS_64=200
ELAPSED_SEC_64=16.94

CONTENT_64='SOLIS_VISION_64_IMAGES_PASS_7F3C94'
IMAGE_TOKENS_64=4096
PROMPT_TOKENS_64=4272
COMPLETION_TOKENS_64=18
FINISH_REASON_64=stop

VISION_64_IMAGES=PASS
~~~

Exactly 65 images:

~~~text
HTTP_STATUS_65=400
ELAPSED_SEC_65=0.01
~~~

Server response:

~~~text
At most 64 image(s) may be provided in one prompt. (parameter=image)
~~~

Result:

~~~text
VISION_65_REJECTED=PASS
VISION_IMAGE_LIMIT_64=PASS
~~~

The configured image-count boundary therefore behaves as intended:
64 images are accepted and 65 images are rejected before inference.

## Validation matrix

| Capability | Result |
|---|---|
| Official stable WSL 2.7.14 | PASS |
| Upstream `v0.2.2-post2` `vllm/**` unchanged | PASS |
| Upstream `launcher.sh` unchanged | PASS |
| TP2 on 2 x RTX 2080 Ti 22 GB | PASS |
| NVLink preflight | PASS |
| 262144 context configuration | PASS |
| FP8 target KV | PASS |
| DFlash2 K=7 | PASS |
| Cold 260000-token inference | PASS |
| 257088-token prefix-cache reuse | PASS |
| DFlash2 replay correctness after prefix reuse | PASS |
| Reasoning disabled | PASS |
| Reasoning enabled | PASS |
| `qwen3_xml` automatic tool calling | PASS |
| Single-image Vision grounding | PASS |
| Exactly 64 images accepted | PASS |
| 65 images rejected | PASS |
| Post-test API health | PASS |
| Post-test NVLink error counters | PASS |

## Production conclusion

For the environment and workloads above, the historical local WSL core patch
bundle is not required in the validated production path.

The validated production state is:

~~~text
upstream v0.2.2-post2 core
+ upstream launcher.sh
+ Solis perimeter tooling only
~~~

Historical allocator, EarlyKV, DXG slab, RoPE staging, MTP allocation, worker,
and KV-planning workarounds remain available in repository history and on the
historical rescue branch, but are retired from the production branch.

This conclusion is intentionally scoped to the validated environment.

It does not assert that the historical workarounds were useless, nor that they
could never be required with another WSL version, Windows commit configuration,
NVIDIA driver, GPU/NVLink state, model, context configuration, or future
upstream revision.

Historical/rescue branch retained unchanged:

~~~text
fix/wsl-long-context-tp2
~~~

No history rewrite or force-push is required.
