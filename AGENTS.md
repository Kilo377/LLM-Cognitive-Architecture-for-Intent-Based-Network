# Agent Notes for 5GORAN

This repository is a MATLAB-oriented 5G/O-RAN simulation workspace.
The codebase mixes top-level MATLAB examples with the main simulation
stack under `oran-sim/`.

## Quick Orientation

- Entry scripts live in `oran-sim/run/`.
- Core simulation components live in `oran-sim/core/`.
- Models are modular and expect a shared `RanContext` state.
- Add the repo to MATLAB path via `oran-sim/run/setup_path.m`.

## Build, Lint, Test

There is no traditional build system in this repo. Use MATLAB to run
scripts and smoke tests.

### Common Commands (MATLAB CLI)

- Add paths then open MATLAB:
  - `matlab -batch "run('oran-sim/run/setup_path.m'); disp('path ready')"`
- Run a baseline scenario (smoke test):
  - `matlab -batch "run('oran-sim/run/setup_path.m'); run_analysis"`
- Run visualization flow:
  - `matlab -batch "run('oran-sim/run/setup_path.m'); run_visualization"`
- Run xApp experiments:
  - `matlab -batch "run('oran-sim/run/setup_path.m'); run_xapp_experiment"`

### Single-Test Guidance

There are no unit tests. Treat each `oran-sim/run/*.m` entry point as a
single scenario test. Use one script per run.

Examples:

- `matlab -batch "run('oran-sim/run/setup_path.m'); run_sensitivity"`
- `matlab -batch "run('oran-sim/run/setup_path.m'); run_conflict_demo"`

### Lint / Code Quality

MATLAB Code Analyzer is the main linting tool.

- Lint a single file:
  - `matlab -batch "checkcode('oran-sim/core/ScenarioBuilder.m')"`
- Lint a directory (shell loop):
  - `matlab -batch "run('oran-sim/run/setup_path.m'); checkcode('oran-sim/core')"`

## Code Style Guidelines

Follow existing conventions in the `oran-sim/` MATLAB code.

### File and Type Layout

- One class or main function per file; file name matches the class or
  function name.
- Classes use `classdef` with `properties` and `methods` sections.
- Scripts and entry points live in `oran-sim/run/` with snake_case names.
- Prefer small, focused model classes in `oran-sim/core/models/`.

### Naming Conventions

- Classes and main modules: `PascalCase` (e.g., `RanKernelNR`).
- Methods and functions: `lowerCamelCase` (e.g., `updateStateBus`).
- Local variables: `lowerCamelCase` or short abbreviations (`numUE`).
- Constants and config fields: mirror `cfg.*` naming in code.
- Per-UE and per-cell vectors: use descriptive suffixes such as
  `PerUE`, `PerCell`, or `_dB`, `_Hz`.

### Formatting and Layout

- 4-space indentation; no tabs.
- Use `%%` section headers and `%% ======` dividers for readability.
- Keep `end` aligned with the matching block.
- Use `...` line continuations for long argument lists.
- Use `isempty` and `isfield` guards before accessing optional structs.

### Imports and Paths

- There is no `import` pattern in MATLAB here; use function/class calls
  directly.
- All run scripts should call `setup_path` once to add paths.
- Avoid modifying MATLAB path inside model classes; keep that in
  `oran-sim/run/setup_path.m`.

### Types and Data Shapes

- Scalars are doubles by default; avoid mixing numeric types unless
  needed.
- Per-UE and per-cell arrays are column vectors (`n x 1`).
- Use structs for action and state buses (`RanActionBus`, `RanStateBus`).
- Prefer `string` for debug output and user-facing labels.
- When returning multiple values, follow MATLAB `[obj, out]` patterns.

### Configuration and State

- Read baseline values from `cfg` (no hard-coded PHY parameters).
- Use `ctx.ctrl` for control knobs and `ctx.tmp` for per-slot values.
- Reset per-slot state only in `ctx.nextSlot()` and `ActionApplierModel`.
- Keep `RanKernelNR` as the authoritative pipeline order.

### Error Handling and Validation

- Validate configuration fields with `isfield` checks.
- Use `assert` or `error` with clear messages for invariant failures.
- For optional fields, provide defaults rather than failing.
- Avoid silent failures; log with `fprintf` or `disp` at key stages.

### Logging and Debugging

- Use the `action.debug` contract in `RanKernelNR` for verbose traces.
- Place per-slot debug values under `ctx.tmp.debug.*`.
- Keep logs concise and start with clear tags (e.g., `[ScenarioBuilder]`).

### Modeling and API Discipline

- Each model `step` should only depend on `ctx.ctrl` and inputs from
  earlier pipeline stages.
- Avoid reading or writing action directly; use the applied `ctx.ctrl`.
- Keep model side effects explicit: update `ctx` fields in one place.
- Ensure kernel order remains: action -> mobility -> traffic -> beam ->
  radio -> handover -> scheduler -> phy -> energy -> kpi -> state bus.

### Visualization and Outputs

- Use `figure`/`subplot` for plotting in run scripts; keep data
  collection and plotting separate.
- Save outputs under `oran-sim/_results_*` with explicit file names.

## Notes on Missing Agent Rules

- No Cursor rules found in `.cursor/rules/` or `.cursorrules`.
- No GitHub Copilot instructions found in `.github/copilot-instructions.md`.

## Tips for New Work

- Start with a run script in `oran-sim/run/` to reproduce behavior.
- Add new models under `oran-sim/core/models/` and wire them in the
  kernel.
- Extend buses in `oran-sim/core/bus_E2/` or `oran-sim/core/bus/` in
  lockstep with model changes.
