# Agentic coding bench for local LLMs

A test stand that measures how well **local** language models (16 GB GPU class) do real
agentic software development: the model works through [OpenCode](https://opencode.ai) on a
multi-stage task, and every stage is accepted or rejected by an automatic gate — not by the
model's own report.

What is tested is the pair *model + hardware*: each model runs with the largest context and
the best sampler settings that this machine allows, found by pretests before the main run.

Scripts, comments and the change history ([CHANGELOG.md](CHANGELOG.md),
[README-v4.1.md](README-v4.1.md)) are in Ukrainian.

## How it works

```
run-v4.sh ── for each model in runs-*.txt
   │   load model (LM Studio, or llama-server directly — per model-rules/)
   │   for each stage in stages-<task>.txt
   │       OpenCode session ──► proxy.py ──► model
   │            │   MCP tools: tools/stand_tools.py (read_lines / edit_lines / write_file /
   │            │              godot_run / stage_check / split_stage)
   │       gate.py <task> <stage>   ✓ → next stage    ✗ → retry with the gate output
   │       3 failed attempts or 2 attempts with no file changes → the model splits the stage
   └── logs/meta.tsv, logs/proxy.tsv, logs/run.out
```

| Part | Role |
|---|---|
| `run-v4.sh` | Runner: model loading, stage queue, attempts, budgets, stage splitting, locks |
| `gate.py`, `bin/stage-check` | Stage acceptance. Each check prints `✓ what` or `✗ what — how to fix` |
| `proxy.py` | Proxy between OpenCode and the model: loop guard (3 identical tool calls), context-overflow trimming, per-model fixes, request log |
| `tools/stand_tools.py` | MCP server with tools that give clear errors and an example of a correct call |
| `tools/probe.gd`, `bin/godot`, `tools/alert-shim/` | Running a Godot game without hangs: screenshots, scene report (empty / washed-out / blocked view), error dialogs returned as text |
| `model-rules/*.json`, `model_rules.py` | One file per model: sampler, server flags, known issues with symptom and workaround |
| `runs-*.txt` | Which models to run: `model key|slug|context` |
| `stages-*.txt` | Stages of a task: `N|what must exist after this stage` |
| `bases/` | Shared starting point for staged tests (stages 0–2 already done) |
| `qa/` | Independent checks after a run |
| `status.sh`, `stand-watch.py`, `orphan-guard.py` | Live status, phone notifications, cleanup of orphaned processes |

Tasks: `pre` (small HTTP service in Docker), `shop` (full-stack web shop: API, frontend,
Prisma, Playwright), `gra` (3D shooting-range game in Godot with Blender-scripted models).

## Requirements

Linux, NVIDIA GPU, Python 3, Docker, `flock`; OpenCode 1.19.5; LM Studio (`lms` CLI) and/or
`llama-server` from llama.cpp (`tools/build-llama-native.sh` builds one for the local CPU);
Godot 4 and Blender for the `gra` task.

Paths are hard-coded: the stand lives in `/home/alex/v4_stand`, models work in
`/home/alex/v4_test/<task>/<slug>`, task specifications are read from
`/home/alex/v4_test/inputs/<task>/TZ.md`. Change `V` and `T` at the top of the scripts for
another machine. The task specifications themselves are not part of this repository.

## Testing a model, step by step

Only one run can use the GPU at a time; every script refuses to start if another run is
active, if `logs/` still holds the previous run, or if a foreign process occupies the GPU.

### 1. Describe the model

Add `model-rules/<slug>.json` (sampler from the model card, `server` block if the model
should run on llama-server directly, known issues) and a line in a runs file:

```
qwen3.8-27b@iq4_xs|qwen3.8-27b-iq4-xs|69632
```

### 2. Pretest: does it fit and how fast is it (~5 min of GPU per model)

```bash
MODELS="<model key>" ./pretest-direct-v42.sh   # start on llama-server, ~100k-token prompt, free VRAM, speed
./pretest-moe-v42.sh                           # MoE models larger than VRAM: smallest -ncmoe N that survives
```

Set the context in the runs file to the largest value that leaves a VRAM reserve.

### 3. Pretest: does it understand the task (15–30 min per model)

```bash
./pretest-shop-v44.sh      # vision probe on a design mock-up + stages 0–1 of the shop task, 15 min per model
./pretest30-shop-v44.sh    # the same stages with 30 min, for models that ran out of time
```

Results go to `archive/pretest-shop-v44-<time>/`: `vision-<slug>.txt` and the run logs.
A model that fails the pretest is excluded from the full run.

If a model loops in its reasoning, replay the captured requests with different samplers
and put the winner into its rules file:

```bash
python3 qa/replay_loops.py --port 1251 --dumps <req dir> --runs 2 --name dry \
        --extra '{"dry_multiplier":0.8,"dry_base":1.75,"dry_allowed_length":4}'
```

### 4. Smoke run

Two or three cases once, to check the stand rather than the model: tools are called,
screenshots reach a vision model, the loop guard writes to `proxy.tsv`, the gate works.

```bash
GRA_BUDGET=2400 RUNS_FILE=$PWD/runs-v4-smoke.txt nohup ./run-v4.sh > logs/run.out 2>&1 &
./status.sh -f
```

### 5. Full run

```bash
./start-shop-v44.sh        # shop task, 6 h per model, stage cap 1.5 h
./start-stage3.sh          # staged test: every model starts from the same base (bases/)
./status.sh -f             # stages passed, current model and stage, time against budget
```

Main knobs of `run-v4.sh` (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `TASKS` | `gra` | `pre`, `shop`, `gra` |
| `RUNS_FILE` | `runs-v4.txt` | models to run |
| `MODELS_ONLY` | — | restrict to listed slugs |
| `STAGES_FILE` | `stages-<task>.txt` | alternative stage list |
| `PRE_BUDGET` / `SHOP_BUDGET` / `GRA_BUDGET` | 3000 / 9000 / 9000 s | time budget per model |
| `STAGE_CAP` | 2700 s | time per attempt |
| `ATTEMPTS` | 3 | attempts per stage before splitting |
| `NOPROG_MAX` | 2 | attempts without file changes before splitting |
| `SPLIT_DEPTH` / `SPLIT_MAX` | 3 / 8 | limits of stage splitting |
| `START_STAGE`, `BASE_DIR` | — | resume from a stage / start from a shared base |

### 6. After the run

Move `logs/` to `archive/<name>/` (each run keeps its own versioned directory; old numbers
are never overwritten), then check the results independently of the model's report:

```bash
SRC=<dir with model results> qa/check-pre.sh     # pre task: own tests, docker build, black-box acceptance
qa/shot-gra.sh <model work dir> <out dir>        # gra task: screenshots of the game for manual review
```

`check_pretest.sh`, run inside a model's `pre` result, builds the image and checks the
service with numbers that are not in the specification.

## Design principles

- The gate decides, not the model: crashes, empty or washed-out screens and uncommitted work fail a stage.
- Same conditions for all models; per-model differences only in `model-rules/` with the reason recorded.
- A model that cannot finish a stage within its limits gets a smaller stage, not more hints or ready code.
- Models may not read the stand's own directory, so they cannot tune answers to the gate.
- Every rule in the stand comes from an observed failure; the data behind each one is in [CHANGELOG.md](CHANGELOG.md).
