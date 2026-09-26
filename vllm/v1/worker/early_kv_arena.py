# SPDX-License-Identifier: Apache-2.0
"""WSL/DXG Early KV Lending Pool.

Prime CUDA backing before model load, but do not keep a giant live tensor.

The primed backing lives in a torch.cuda.MemPool(use_on_oom=True):
- model construction may borrow cached backing instead of issuing a failing
  late cudaMalloc/DXG create_allocation;
- KV backing is later allocated explicitly from the same private pool;
- strict mode verifies that KV backing itself causes zero new device
  allocations.
"""

from __future__ import annotations

import os
from dataclasses import dataclass

import torch

from vllm.logger import init_logger

logger = init_logger(__name__)

_GIB = 1 << 30
_MARKER_DIR = "/mnt/f/00_WSL/diagnostics"


def durable_marker(stage: str) -> None:
    """Persist a startup stage outside the WSL ext4 VHD."""
    import datetime

    mem_available_kb = "?"
    swap_free_kb = "?"

    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    mem_available_kb = line.split()[1]
                elif line.startswith("SwapFree:"):
                    swap_free_kb = line.split()[1]
    except OSError:
        pass

    pid = os.getpid()
    path = os.path.join(
        _MARKER_DIR,
        f"early-kv-blackbox.{pid}.log",
    )

    line = (
        f"{datetime.datetime.now().isoformat(timespec='microseconds')} "
        f"pid={pid} stage={stage} "
        f"MemAvailable_kB={mem_available_kb} "
        f"SwapFree_kB={swap_free_kb}\n"
    ).encode()

    os.makedirs(_MARKER_DIR, exist_ok=True)

    fd = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_SYNC,
        0o644,
    )
    try:
        os.write(fd, line)
        os.fsync(fd)
    finally:
        os.close(fd)


class EarlyKVArenaExhausted(RuntimeError):
    pass


@dataclass
class _ArenaState:
    pool: torch.cuda.MemPool
    device: torch.device
    capacity: int
    resident_bytes: int
    profile_accounted: bool = False


_STATE: _ArenaState | None = None


def _is_wsl() -> bool:
    return bool(os.environ.get("WSL_DISTRO_NAME"))


def configured_gib() -> float:
    raw = os.environ.get("VLLM_WSL_EARLY_KV_GIB", "5.0")
    try:
        value = float(raw)
    except ValueError as exc:
        raise ValueError(
            f"VLLM_WSL_EARLY_KV_GIB must be a number, got {raw!r}"
        ) from exc

    if value < 0:
        raise ValueError(
            "VLLM_WSL_EARLY_KV_GIB must be >= 0"
        )

    return value


def configured_bytes() -> int:
    return int(configured_gib() * _GIB)


def strict_mode() -> bool:
    raw = os.environ.get(
        "VLLM_WSL_EARLY_KV_STRICT",
        "1",
    ).strip().lower()

    if raw in {"1", "true", "yes", "on"}:
        return True

    if raw in {"0", "false", "no", "off"}:
        return False

    raise ValueError(
        "VLLM_WSL_EARLY_KV_STRICT must be one of "
        "0/1/false/true/no/yes/off/on"
    )


def enabled() -> bool:
    return _is_wsl() and configured_gib() > 0


def _state_for(device: torch.device) -> _ArenaState:
    if _STATE is None:
        raise RuntimeError(
            "WSL Early KV Lending Pool is enabled but "
            "was not primed before model load"
        )

    device = torch.device(device)

    if _STATE.device != device:
        raise RuntimeError(
            "Early KV lending pool device mismatch: "
            f"pool={_STATE.device}, request={device}"
        )

    return _STATE


def _pool_segments(state: _ArenaState) -> list[dict]:
    snapshot = state.pool.snapshot()

    # Current CUDA MemPool.snapshot() returns a list. Keep this tolerant
    # in case a downstream torch build wraps it in {"segments": ...}.
    if isinstance(snapshot, dict):
        return list(snapshot.get("segments", []))

    return list(snapshot)


def _pool_free_stats(
    state: _ArenaState,
) -> tuple[int, int]:
    """Return (total inactive bytes, largest inactive block)."""
    total = 0
    largest = 0

    for segment in _pool_segments(state):
        for block in segment.get("blocks", []):
            if block.get("state") != "inactive":
                continue

            size = int(block.get("size", 0))
            total += size
            largest = max(largest, size)

    return total, largest


def reserve(
    device: torch.device,
) -> torch.cuda.MemPool | None:
    """Prime a private lending pool before model load."""
    global _STATE

    if not enabled():
        return None

    device = torch.device(device)

    if device.type != "cuda":
        raise RuntimeError(
            "WSL Early KV Lending Pool requires CUDA"
        )

    if _STATE is not None:
        if _STATE.device != device:
            raise RuntimeError(
                f"Early KV pool already belongs to "
                f"{_STATE.device}, requested {device}"
            )
        return _STATE.pool

    capacity = configured_bytes()
    gib = capacity / _GIB

    durable_marker("LENDING_POOL_ENTER")

    logger.info(
        "WSL early KV lending pool priming %.3f GiB "
        "before model load",
        gib,
    )

    free_before, _ = torch.accelerator.get_memory_info(
        device
    )

    durable_marker("LENDING_POOL_CREATE_BEGIN")

    try:
        # use_on_oom=True is the key:
        # normal allocations outside this pool may borrow cached
        # blocks from it as a last resort rather than immediately
        # issuing another failing cudaMalloc/DXG transaction.
        pool = torch.cuda.MemPool(
            use_on_oom=True,
        )
    except TypeError as exc:
        raise RuntimeError(
            "This torch build does not support "
            "torch.cuda.MemPool(use_on_oom=True)"
        ) from exc

    durable_marker("LENDING_POOL_CREATE_END")
    durable_marker("LENDING_POOL_PRIME_BEGIN")

    # Allocate/touch the backing while WSL/DXG is still in the known-good
    # early-startup state.
    #
    # IMPORTANT: the primer tensor is deliberately deleted. The pool
    # object remains alive, so the backing becomes INACTIVE/CACHED rather
    # than an active 5 GiB tensor competing with model construction.
    with torch.cuda.use_mem_pool(
        pool,
        device=device,
    ):
        primer = torch.empty(
            capacity,
            dtype=torch.int8,
            device=device,
        )

        durable_marker("LENDING_POOL_PRIME_ALLOCATED")

        primer.zero_()
        torch.accelerator.synchronize(device)

        durable_marker("LENDING_POOL_PRIME_TOUCHED")

        del primer

    torch.accelerator.synchronize(device)

    durable_marker("LENDING_POOL_PRIME_RELEASED")

    free_after, _ = torch.accelerator.get_memory_info(
        device
    )

    resident = max(
        0,
        int(free_before - free_after),
    )

    _STATE = _ArenaState(
        pool=pool,
        device=device,
        capacity=capacity,
        resident_bytes=resident,
    )

    free_cached, largest = _pool_free_stats(_STATE)

    durable_marker("LENDING_POOL_REGISTERED")

    logger.info(
        "WSL early KV lending pool primed: "
        "%.3f GiB requested, %.3f GiB resident",
        gib,
        resident / _GIB,
    )

    logger.info(
        "WSL early KV lending pool cached free: "
        "%.3f GiB total, %.3f GiB largest block",
        free_cached / _GIB,
        largest / _GIB,
    )

    return pool


def rewind(device: torch.device) -> None:
    """Synchronize before reusing cached pool backing."""
    if not enabled() or _STATE is None:
        return

    state = _state_for(device)

    torch.accelerator.synchronize(device)

    free_cached, largest = _pool_free_stats(state)

    logger.info(
        "WSL early KV lending pool before final KV: "
        "%.3f GiB cached free, %.3f GiB largest block",
        free_cached / _GIB,
        largest / _GIB,
    )


def take(
    size: int,
    device: torch.device,
    *,
    zero: bool = True,
) -> torch.Tensor:
    """Allocate KV backing from already-primed private pool."""
    if size < 0:
        raise ValueError(
            f"Early KV pool allocation size must be >= 0, "
            f"got {size}"
        )

    state = _state_for(device)
    size = int(size)

    free_cached, largest = _pool_free_stats(state)

    # In strict mode, do not even attempt an allocation that cannot be
    # served by an existing cached block. That prevents this function
    # from becoming another late cudaMalloc -> DXG -75 site.
    if (
        strict_mode()
        and size > 0
        and largest < size
    ):
        raise EarlyKVArenaExhausted(
            "WSL Early KV Lending Pool has no cached block "
            "large enough for KV backing: "
            f"need={size / _GIB:.3f} GiB, "
            f"cached_total={free_cached / _GIB:.3f} GiB, "
            f"largest={largest / _GIB:.3f} GiB"
        )

    before = num_device_alloc(device)

    with torch.cuda.use_mem_pool(
        state.pool,
        device=device,
    ):
        buf = torch.empty(
            size,
            dtype=torch.int8,
            device=device,
        )

        if zero and size:
            buf.zero_()

    after = num_device_alloc(device)

    if strict_mode() and after != before:
        raise RuntimeError(
            "WSL Early KV Lending Pool KV allocation "
            f"caused {after - before} new device allocation(s)"
        )

    return buf


def exclude_from_profile(profile_result) -> None:
    """Credit only still-free primed pool bytes back to KV capacity.

    Model weights borrowed through use_on_oom remain active and are NOT
    deducted. Only inactive cached bytes that can actually be reused by
    KV are excluded from non-KV consumption.
    """
    if (
        not enabled()
        or _STATE is None
        or _STATE.profile_accounted
    ):
        return

    state = _STATE

    free_cached, largest = _pool_free_stats(state)

    deduct = min(
        int(free_cached),
        int(profile_result.total_consumed),
    )

    profile_result.total_consumed = max(
        0,
        int(profile_result.total_consumed) - deduct,
    )

    profile_result.non_kv_cache_memory = max(
        0,
        int(profile_result.non_kv_cache_memory) - deduct,
    )

    state.profile_accounted = True

    logger.info(
        "WSL early KV lending pool profile credit: "
        "%.3f GiB reusable for KV "
        "(largest block %.3f GiB)",
        deduct / _GIB,
        largest / _GIB,
    )


def num_device_alloc(
    device: torch.device,
) -> int:
    stats = torch.accelerator.memory_stats(device)
    return int(
        stats.get(
            "num_device_alloc",
            0,
        )
    )


def verify_no_device_alloc(
    device: torch.device,
    before: int,
) -> int:
    after = num_device_alloc(device)
    delta = after - int(before)

    if delta == 0:
        logger.info(
            "KV raw backing allocation "
            "num_device_alloc delta == 0"
        )
        return 0

    msg = (
        "KV raw backing allocation "
        f"num_device_alloc delta == {delta}"
    )

    if strict_mode():
        raise RuntimeError(
            msg
            + " (STRICT Early KV Lending Pool "
            "forbids late device allocation)"
        )

    logger.warning(msg)
    return delta


def release() -> None:
    """Drop process-level pool reference for tests/teardown."""
    global _STATE
    _STATE = None
