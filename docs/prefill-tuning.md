# Prefill tuning on ac-box, 14 Sep 2026

The deployed `agent-hub-llm` (Qwen3-Coder-Next 80B-A3B, Q8_0, nixpkgs
`llama-cpp` b9190) measured **17 tok/s prefill, 4.5 tok/s generation** on a
1707-token prompt: 99 seconds of silence before the first output token. A
4k-token prompt was five minutes. `homelab-route` was written around that
number.

One night of measurement later, the same model on the same box does **140
tok/s prefill, 13.3 tok/s generation, first token in 12 s**, and the unit is
healthy 17 s after start instead of six minutes. Nothing about the model or
the hardware changed. This document is the evidence and the reasoning, so
the next person does not have to redo it -- and so the two comments in
`homelab` that turned out to be wrong are corrected with numbers, not
opinions.

## The box

Dual-socket Xeon E5-2680 v4 (Broadwell: AVX2/FMA, **no AVX-512**), 2 x 14
physical cores, SMT on, 251 GiB DDR4 across two NUMA nodes:

| node | cpus | siblings |
| --- | --- | --- |
| 0 | 0-13 | 28-41 |
| 1 | 14-27 | 42-55 |

The tenant contract fences `background.slice` (where the server lives) to
`3-25,31-53`: 11 physical cores on socket 0, 12 on socket 1, plus their SMT
siblings. Every run below happened inside that fence -- the race servers on
cores 0-2 never saw the benchmark.

## Method

`scripts/bench/bench.sh` runs `llama-bench` on the box as a transient systemd
unit inside `background.slice`, with the cpuset and NUMA policy set as unit
properties (`AllowedCPUs=`, `NUMAPolicy=`, `NUMAMask=`) -- the same knobs the
real unit gets. The live server stays up: both processes mmap the same GGUF,
so the page cache is shared and a run costs no reload. `scripts/bench/batch*.sh`
are the exact sweeps; `results/all.jsonl` (gitignored) is what `table.sh`
renders.

Two things the harness got wrong first, kept here so they are not repeated:

- **Do not restrict CPUs with llama-bench's own `-C`/`--cpu-strict`.** The
  compute threads got pinned one-per-core as intended, but the idle OpenMP
  pool (35 threads) inherited the main thread's affinity and piled onto a
  single core with the compute thread already there. Load average 39 for a
  12-thread run. The unit's cpuset confines every thread and costs nothing.
- **ik_llama.cpp's first repetition is a warm-up outlier** (the harness passes
  `-w 0`, so nothing absorbs it; mainline's runs did not show this). Two-rep averages
  with a ±20 stddev are that. Decisions below use the steady-state sample
  or 4k/8k prompts where warm-up is amortised.

pp = prompt processing (prefill) tok/s; tg = generation tok/s. `-t` is
threads. All prompts 1024 tokens unless the test column says otherwise.

## Finding 1: the model lived entirely on one socket

`/proc/<pid>/numa_maps` for the deployed server: all four shards **N0=0,
N1=100 %** -- 85 GB mlocked on node 1. `--numa distribute` spreads
*threads* across nodes; it sets no memory policy. mmap'd pages land wherever
the loader's first touch happens and `--mlock` freezes them there. The
`homelab` comment that called `--numa distribute` "THE flag on this box"
because "without it llama.cpp allocates on whichever node loaded the model"
described the flag's intent, not its effect.

Batch 1, pages on node 1, mainline b9190:

| run | cores | pp1024 | tg32 |
| --- | --- | --- | --- |
| node 1 only, 12 physical (all local) | 14-25 | 23.2 | 6.87 |
| node 0 only, 11 physical (all remote) | 3-13 | 21.4 | 3.63 |
| both sockets, 23 physical | 3-25 | 30.3 | 4.95 |
| node 1 + SMT, 24 threads | 14-25,42-53 | 24.1 | **7.53** |
| whole fence, 46 threads | fence | **33.1** | 5.73 |
| 23 threads, `--numa distribute` | fence | 16.1 | 4.74 |
| 46 threads, `--numa distribute` | fence | 22.6 | **0.15** |

Generation is a memory-placement story (6.9 local vs 3.6 remote on the same
kernels); prefill barely notices (compute-bound, ~2 tok/s per core).

## Finding 2: `--numa distribute` was the most harmful flag in the unit

Same threads, same pages: 30.3 -> 16.1 pp at 23 threads, 33.1 -> 22.6 at 46,
and at 46 threads it collapses generation to 0.15 tok/s. Its per-node thread
pinning fights the cgroup fence. The deployed unit ran `--threads 23
--threads-batch 46 --numa distribute`, i.e. the 16.1 / 4.74 row for
generation and the 22.6 row for prefill -- which is the 17 / 4.5 the baseline
measured.

With nothing but flag changes, mainline reaches 33 pp / 7.5 tg. That is where
the gain from mainline ends: it does not scale past one socket's worth of
cores, and interleaving the pages across both nodes (batch 2) moved its
generation from 4.95 to 5.8 and its prefill not at all.

## Finding 3: ik_llama.cpp is the 5x

[ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) (`3bb386e`, built by
`nix/ik-llama-cpp.nix`: generic AVX2/FMA/F16C, no `-march=native`, no BLAS)
on the *same pages and cores* as the mainline rows:

| run | build | cores | pp1024 | tg32 |
| --- | --- | --- | --- | --- |
| whole fence, 23 threads, interleaved pages | main b9190 | fence | 29.9 | 5.8 |
| whole fence, 23 threads, interleaved pages | ik | fence | 99.2 | 12.2 |
| **physical cores only**, 23 threads, interleaved | ik | 3-25 | **121.6** | 12.45 |
| node 1 only, 12 threads, interleaved | ik | 14-25 | 77.6 | 8.5 |

Its `iqk_mul_mat` kernels and fused MoE ops are what mainline's
`mul_mat_id` path lacks on CPU for this quant. Unlike mainline, ik scales
across both sockets (77.6 on one, 121.6 on two), so two-socket interleave is
the right placement once the kernels can consume the bandwidth. Confining
the unit to physical cores (`AllowedCPUs=3-25`) is worth ~20 % prefill on
its own: threads that land on SMT siblings hurt.

## The remaining flags, on the candidate shape

All ik, `AllowedCPUs=3-25`, `NUMAPolicy=interleave`. Steady-state
(second-rep) pp1024 in parentheses where the 2-rep average was noisy.

| flag | pp1024 | tg32 | verdict |
| --- | --- | --- | --- |
| `-fa 1` (baseline) | 119 (140) | 12.4 | keep on |
| `-fa 0` | 139 | 13.3 | ~4 % faster even at 8k (125 vs 119) but FA is the memory-safe choice at 32k ctx; not worth a flag |
| `-rtr 1` run-time repack, no mmap | 137 (146) | 12.9 | **in**: +5-6 % (137 vs 128 at pp4096) and NUMA placement becomes deterministic -- anon memory allocated under the unit's policy, independent of page-cache history |
| `-rtr -muge 1` | 137 | 13.4 | noise; its load pass takes 100 s vs 20 s |
| `-rtr -thp 1` | 140 | 13.2 | noise |
| `-t 22` | 134 (135) | 12.7 | no better than 23 once warm-up is excluded |
| `-ub 1024` | 101 vs 99 | -- | noise |
| `kernel.numa_balancing=0` | 99.5 vs 99.2 | 12.35 vs 12.2 | no effect (mlocked/anon pages cannot migrate anyway); the llama.cpp start-up warning can be ignored |
| pp4096 | 128 (fa1) / 137 (rtr) | -- | a 4k prompt in ~30 s |
| pp8192 | 119 (fa1) / 125 (fa0) | -- | |
| generation after a 4k prompt (`-pg 4096,64`) | | ~14 | no degradation with depth: the DeltaNet layers are linear in context |

## The unit shape that shipped

```
engine        ik-llama-cpp                    (services.agent-hub.llm.engine)
threads       23                              (unchanged)
extraArgs     -rtr --flash-attn on --metrics  (dropped: --numa distribute, --threads-batch 46, --mlock)
serviceConfig AllowedCPUs=3-25  NUMAPolicy=interleave  NUMAMask=0-1
```

`--mlock` goes because with `-rtr` there is no mmap and the box has no swap:
nothing to pin against. `--threads-batch 46` goes because the cpuset now
holds 23 CPUs. Validated end to end with ik's `llama-server` on a side port,
replaying the baseline's exact 1707-token request twice:

| | deployed | candidate |
| --- | --- | --- |
| prefill | 17.2 tok/s | 140 tok/s |
| time to first token | 99 s | 12 s |
| generation | 4.5 tok/s | 13.3 tok/s |
| healthy after start | ~6 min | 17 s |
| model pages | 85 GB on node 1 | 39.9 / 39.9 GiB |

`/v1/chat/completions` (what aider and `hub-ask.sh` speak) answers with the
chat template applied and `usage` populated.

## What this changes upstream of the box

- `homelab-route`'s table and `hub-ask.sh`'s budget comment were written for
  13 tok/s prefill. At 140 the 6k-token budget is ~45 s, not ~8 minutes, and
  the full 32k context is under four minutes, not forty. Both should be
  re-derived from this document once the switch has been watched.
- `configuration.nix`'s `contextSize = 32768` comment says "raise it once a
  measured prefill rate says it is affordable". It now does.

## Not tried

- A Q4_0 / Q4_K requant: repackable to AVX2 GEMM tiles in both builds and
  probably the largest remaining prefill lever, but it changes the model.
- The BLAS variant of ik (`useBlas = true`); the fork's own kernels were the
  point of testing it.
- Anything on the GPU-less assumption itself.
