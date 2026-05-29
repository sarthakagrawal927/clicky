# FM eval fixtures

Plain-text fixtures consumed by `scripts/eval-fm.sh` and
`scripts/eval-compare-planners.sh`.

## Fixture format

```
USER: <transcript the user spoke>
ELEMENT: [N] role|x,y|label|text
ELEMENT: [N+1] role|x,y|label|text
...

# Optional scoring fields (any/all):
EXPECT_POINT_ID: 3              # exact match required (-1 = must refuse / no target)
EXPECT_POINT_ID_ONE_OF: 3,7,12  # any of these IDs acceptable (use for ambiguous targets)
EXPECT_CLICK_ID: 3              # exact match required (-1 = must refuse)
EXPECT_CLICK_ID_ONE_OF: 3,7     # any acceptable
SPOKEN_MUST_CONTAIN: pace        # case-insensitive substring
SPOKEN_MUST_NOT_CONTAIN: ID,coord,element  # comma-separated forbidden substrings
SPOKEN_MAX_WORDS: 12             # spokenText word count cap
```

If a fixture omits all `EXPECT_*` lines, eval-fm.sh runs it for
diagnostic output only — no pass/fail score. Use this for
exploration; convert to scored when behavior is locked in.

Scoring is strict: every EXPECT_* present must pass for the
fixture to count as passing.
