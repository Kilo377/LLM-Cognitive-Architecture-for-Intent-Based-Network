# Intent Tutorial (SMO + MATLAB Non-RT)

This tutorial shows how to write an intent in SMO and get xApp selection results by running the MATLAB Non-RT scenario.

## Goal

- Put your intent text into SMO config
- Run MATLAB `run_nonrt_general`
- Observe which xApps are selected and applied

## How It Works

1. MATLAB `run_nonrt_general` runs the simulator.
2. Non-RT RIC writes a report to `oran-sim/bus_A1/non_rt_report.json`.
3. Non-RT RIC invokes SMO Python (`oran-sim/smo/smo.py`).
4. SMO reads `intent_text` from `oran-sim/smo/config.json`.
5. SMO outputs policy to `oran-sim/bus_A1/non_rt_policy.json`.
6. Non-RT RIC applies policy to Near-RT RIC (enabled xApps).

## Step 1: Edit Intent

Open `oran-sim/smo/config.json` and set `intent_text`.

Example:

```json
{
  "orchestrator": "graph",
  "provider": "ollama",
  "model": "qwen2.5:14b",
  "intent_text": "Increase throughput without degrading fairness"
}
```

You can write intent in English or Chinese. Keep it clear and KPI-oriented.

## Step 2: Check SMO Command Path

Open `oran-sim/run/default_config.m` and verify `cfg.nonRT.smoCommand` points to your local Python + `smo.py` path.

If this path is invalid, Non-RT will not get a policy from SMO.

## Step 3: Run Non-RT Scenario

From repository root:

```bash
matlab -batch "run('oran-sim/run/setup_path.m'); run_nonrt_general"
```

## Step 4: Read Selection Results

During execution, check MATLAB console output for:

- `===== Non-RT Policy Selection =====`
- `Enabled xApps: ...`
- `KPI focus: ...`

These lines indicate the selected xApps from your intent-driven policy.

You can also inspect generated files:

- Report: `oran-sim/bus_A1/non_rt_report.json`
- Policy: `oran-sim/bus_A1/non_rt_policy.json`
- Optional reasoning log: `oran-sim/smo/last_reasoning_log.json`

## Quick Troubleshooting

- No selection printed:
  - Ensure `cfg.nonRT.triggerTime_s` is within simulation time.
  - Ensure `cfg.sim.slotPerEpisode` is long enough.
- Policy not generated:
  - Check `cfg.nonRT.smoCommand` path.
  - Run SMO manually once for diagnosis:

```bash
python "oran-sim/smo/smo.py"
```

- Intent seems ignored:
  - Confirm `intent_text` is non-empty in `oran-sim/smo/config.json`.
