# Today's 5 Selection Algorithm

How the app picks 5 tasks for the daily focus view.

## Overview

Today's 5 uses **weighted random selection** with normalization and diversity controls to pick a balanced, engaging set of tasks each day. The algorithm runs in two contexts: **fresh generation** (new day / "New set") and **swap** (replacing a single task).

## Candidate Pool

Only **leaf tasks** (tasks with no active children) are eligible. Additional filters:

| Filter | Reason |
|--------|--------|
| Not completed | Already done |
| Not skipped | User opted out |
| Not blocked | Has unfinished dependencies |
| Not worked on today | Already had attention today |
| Not already in Today's 5 | No duplicates (swap only) |

## Weight Formula

Each candidate gets a base weight of `1.0`, multiplied by several independent factors:

```
weight = 1.0
       * priority_boost        (high priority: 3.0x — mutually exclusive with someday)
       * started_boost          (in progress: 2.0x — someday tasks skip)
       * staleness_boost        (1.0 + 0.25 * ln(days + 1), clamped 1.0–2.0 — someday tasks skip)
       * novelty_boost          (created ≤ 3 days ago: 1.3x — someday tasks skip)
       * deadline_boost         (within 14 days: 1.0 + 7.0/(|days| + 1))
       * schedule_boost         (scheduled for today: 2.5x)
       * normalization_factor   (1/sqrt(N) where N = leaf count under root)
```

> **Someday tasks** skip started, staleness, and novelty boosts — they stay at base weight `1.0` (plus deadline/schedule/normalization if applicable). High priority is mutually exclusive with someday (toggling one clears the other).

### Factor Details

**Priority** — High-priority tasks get 3x weight. This is the strongest single factor.

**Started** — Tasks the user has started working on get 2x, reflecting commitment. Someday tasks skip this.

**Staleness** — Logarithmic curve based on days since last touched (`lastWorkedAt` → `startedAt` → `createdAt`). Ensures neglected tasks surface. Someday tasks skip this.

**Novelty** — Newly created tasks (≤ 3 days) get a 1.3x bump so they appear soon after creation. Someday tasks skip this.

**Deadline proximity** — Hyperbolic boost within 14 days of deadline:
- Due today: 8.0x
- Due in 1 day: 4.5x
- Due in 3 days: 2.75x
- Due in 7 days: 1.875x
- Due in 14 days: 1.47x

**Schedule boost** — Tasks scheduled for the current day of the week get 2.5x. Schedule propagates from ancestors (stops at schedule barriers — tasks with their own schedule or explicit override flag).

**Root normalization** — `1/sqrt(N)` where N is the leaf count under the task's root ancestor. Dampens volume advantage of large categories. For multi-parent tasks, uses the minimum leaf count across roots (most generous normalization).

Examples:
- Root with 100 leaves: factor = 0.1x
- Root with 10 leaves: factor ≈ 0.316x
- Root with 1 leaf: factor = 1.0x

## Selection Algorithm (Weighted Roulette)

```
picked = []
rootPickCounts = {...existingRootPickCounts}  // seeded for swap

while picked.length < slotsToFill and remaining is not empty:
    for each candidate in remaining:
        w = computeWeight(candidate)

        // Diversity penalty: penalize same-root picks
        if normData available and rootPickCounts not empty:
            maxPicks = max picks from any of candidate's roots
            if maxPicks > 0:
                w *= 0.3 ^ maxPicks

        weights.append(w)

    // Roulette wheel selection
    total = sum(weights)
    roll = random(0, total)
    for i in 0..remaining.length:
        roll -= weights[i]
        if roll <= 0: pick = remaining[i]; break

    picked.append(pick)
    remaining.remove(pick)
    update rootPickCounts for pick's roots
```

### Diversity Penalty

After each pick, tasks sharing roots with already-picked tasks get a multiplicative penalty:
- 1st pick from a root: no penalty
- 2nd pick from same root: 0.3x (70% reduction)
- 3rd pick from same root: 0.09x (91% reduction)
- 4th pick from same root: 0.027x (97% reduction)

This strongly encourages spread across different root categories without making it impossible to pick multiple tasks from the same root.

## Generation vs Swap

### Fresh Generation (`_generateNewSet`)

1. Keep completed + pinned tasks from previous set
2. Auto-pin deadline tasks (due today or overdue)
3. Fetch `_SelectionContext` (all leaves, blocked IDs, schedule boosts, deadline data, normalization)
4. Fill remaining slots via weighted roulette with full normalization + diversity penalty

### Swap (`_swapTask`)

1. Fetch same `_SelectionContext` (shared `_fetchSelectionContext` helper)
2. **Seed `rootPickCounts`** from current Today's 5 (excluding the slot being replaced)
3. Pick 1 task via weighted roulette with full normalization + diversity penalty
4. The seeded counts ensure the replacement respects existing root spread

### Deadline Auto-Pinning

Tasks with deadlines due today (or overdue) are automatically pinned into Today's 5. These are added before the weighted selection runs, consuming slots. They respect the user's manual unpin — if the user unpins a deadline task, `is_deadline_auto_unpin` is set and that task won't be auto-pinned again.

## Key Implementation Files

| Component | File | Key Function |
|-----------|------|-------------|
| Weight formula | `lib/providers/task_provider.dart` | `_taskWeight()` |
| Weighted selection | `lib/providers/task_provider.dart` | `pickWeightedN()` |
| Normalization data | `lib/data/database_helper.dart` | `getNormalizationData()` |
| Root ancestor lookup | `lib/data/database_helper.dart` | `getRootAncestorsForLeaves()` |
| Leaf count per root | `lib/data/database_helper.dart` | `getLeafCountPerRoot()` |
| Schedule boost | `lib/data/database_helper.dart` | `getScheduleBoostedLeafIds()` |
| Deadline boost | `lib/data/database_helper.dart` | `getDeadlineBoostedLeafData()` |
| Selection context | `lib/screens/todays_five_screen.dart` | `_fetchSelectionContext()` |
| Fresh generation | `lib/screens/todays_five_screen.dart` | `_generateNewSet()` |
| Swap | `lib/screens/todays_five_screen.dart` | `_swapTask()` |
| Pin management | `lib/data/todays_five_pin_helper.dart` | `TodaysFivePinHelper` |

## Future Considerations

### Reserved Slots for Scheduled Tasks

Research (stratified sampling, Reclaim.ai, ADHD literature) suggests **reserving 1 slot** for scheduled-for-today tasks rather than relying solely on weight boosting. Weight boosts are probabilistic and can be overwhelmed by stacking other multipliers. A reserved slot guarantees the user's scheduling intent is respected. See `memory/research_scheduled_task_fairness.md` for full analysis.

### Inferred Task Cadence

Auto-detect recurring habits from completion patterns (e.g., "walk" completed every ~2 days → boost when overdue). Would add a new weight factor without user configuration. See TODO.md "Inferred Task Cadence" section for phased approach.

### Stronger Normalization

Current `1/sqrt(N)` is a good middle ground. `1/N` was considered but rejected — it over-penalizes large categories (a root with 20 leaves gets 0.05x, making high-priority tasks nearly invisible). If volume imbalance worsens, a tunable exponent `1/N^k` where `0.5 < k < 1.0` could be explored.

### Energy-Level Matching

Optional effort tags (low/med/high) on tasks; filter or boost based on current energy level. Would add a user-input dimension to weight calculation alongside the existing priority field. Note: a "quick task" difficulty flag existed previously (vestigial `difficulty` column still in DB schema) but was removed from the Task model and UI due to low usage.

### Schedule Inheritance Rethink

Currently, scheduling a parent boosts all leaf descendants. A child with its own schedule acts as a **barrier** — it blocks parent schedule propagation and only uses its own schedule days. The `schedule_barrier` CTE in `getScheduleBoostedLeafIds` enforces this. Open question: is this barrier behavior always desirable, or should there be more nuanced inheritance controls? See TODO.md for details.
