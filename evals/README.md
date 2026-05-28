# Pace Evals

Reproducible fast + correct checks for the local planner pipeline.

## Why this exists

Two things move regularly and need ongoing measurement:

- **Latency.** Every system-prompt tweak, every conversation-history change, every model swap pushes TTFT up or down. Without a fixture suite we're guessing.
- **Behavior.** The local planner is non-deterministic — what worked yesterday with Qwen3-14B at temperature 0.4 may regress today with Qwen3-1.7B at temperature 0. We need to catch "planner started emitting markdown again," "agent rules leaked into a non-action turn," etc.

Both eval kinds live here. They run against your real `localhost:1234` LM Studio, not against mocks — the whole point is to measure what the user actually feels.

## Running

```bash
# Hit every fixture, print pass/fail table.
./scripts/eval-pace.sh

# Run a single fixture by name.
./scripts/eval-pace.sh qa-no-screen

# Skip the speed evals (faster, only checks correctness).
./scripts/eval-pace.sh --no-latency
```

The script reads the planner endpoint + model identifier from `leanring-buddy/Info.plist`, so it always evaluates whatever Pace itself would call.

## Fixtures

Each fixture is a single JSON file under `fixtures/`:

```json
{
  "name": "qa-no-screen",
  "category": "qa",
  "request": {
    "messages": [
      {"role": "system", "content": "<system prompt — keep in sync with CompanionSystemPrompt.swift>"},
      {"role": "user", "content": "what is html?"}
    ],
    "temperature": 0,
    "max_tokens": 200
  },
  "expectations": {
    "max_ttft_ms": 1500,
    "must_contain_patterns": ["html", "markup"],
    "must_not_contain_patterns": ["\\[CLICK", "\\[TYPE", "\\[KEY", "^\\s*-\\s", "\\*\\*"]
  }
}
```

Field reference:

| Field | Purpose |
|---|---|
| `name` | Unique fixture id — file name without `.json`. |
| `category` | Used to bucket the latency report (`qa`, `screen-referential`, `action`, etc.). |
| `request` | Verbatim body POSTed to `/v1/chat/completions` (apart from `model`, which the script injects from Info.plist). |
| `expectations.max_ttft_ms` | TTFT budget. Failing means too slow. |
| `expectations.must_contain_patterns` | List of regexes that MUST appear (case-insensitive) in the response. |
| `expectations.must_not_contain_patterns` | List of regexes that MUST NOT appear. |

## Budgets

`budgets.json` is a per-category latency target you can paste into the README hero number. Today's targets are aspirational — the point is to see how the numbers move as we iterate, not to gate releases.

## Drift caveat

The fixtures embed a system prompt. That string is a snapshot of `CompanionSystemPrompt.swift` at the time the fixture was written. When the real prompt changes, update the fixtures — otherwise the evals stop reflecting reality. There's a comment marker `<!-- system-prompt-version: N -->` near the top of each fixture to track which generation it's from.
