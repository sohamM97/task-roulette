# Design Psychology: ADHD-Friendly Task System

> **TL;DR:** Every feature reduces decisions. No streaks. No guilt. No punishment. Just gentle nudges and easy wins.

---

## The One Rule

**If it makes the user think more, it's wrong.**

ADHD = impaired executive function = the brain's "manager" is overloaded. Every unnecessary choice taxes it further.

---

## 1. Three Ways to Finish (replaces explicit repeating)

**The old model** had explicit "repeating" tasks with schedules. Too much config, too many concepts.

**The new model:** Every task gets the same three actions:

| Action | What it does | When to use |
|--------|-------------|-------------|
| **In progress** | Marks as started, stays visible today | "I'm working on this" |
| **Done today** | Hides for today, back tomorrow | "Made progress, done for now" |
| **Done for good!** | Permanently complete | "This is finished" |

**Why this works:**
- **No explicit repeating** — "Done today" is implicit recurrence. Exercise today? "Done today." It comes back tomorrow. No interval config needed.
- **"In progress" acknowledges effort** — tapping it says "I started." The Ovsiankina effect (1928) — the tendency to *resume* interrupted tasks — gives started tasks a gentle pull. Note: for ADHD, open loops can also cause anxiety (Masicampo & Baumeister, 2011), so we pair this with easy ways to close the loop ("Done today") rather than letting tasks nag indefinitely.
- **Partial work counts** — crucial for ADHD motivation (Amabile & Kramer, 2011). "Done today" rewards any engagement, not just completion.
- **No overdue** — tasks just reappear. Negative feedback amplifies avoidance (Shaw et al., 2014).

**What we don't do:**
- No streak tracking ("you worked on this 3/5 days this week")
- No punishment for missing days
- No counting at all — just today / not today
- No *complex* schedules (intervals, cron-like recurrence, time-of-day) — see §5 for our lightweight alternative

---

## 3. Weighted Random

**Same shuffle button. Smarter picks. Zero extra decisions.**

| Factor | Weight | Why |
|--------|--------|-----|
| High priority | 3x | User said it matters |
| Started | 2x | Commitment consistency (Cialdini, 2006) |
| Stale (logarithmic) | 1x → 2x cap | Gentle rescue from neglect (see below) |
| New (< 3 days) | 1.3x | Capitalize on initial enthusiasm |
| Someday | no staleness | Aspirational tasks don't create pressure |
| Scheduled today | 2.5x | Gentle day-of-week nudge (see §5) |

**Staleness curve:** `1 + 0.25 × ln(days + 1)`, capped at 2×. Grows fast in the first week (surfaces genuinely forgotten tasks), then flattens. A task untouched for 7 days gets ~1.6×; at 30 days it hits the 2× cap. The old linear model (4× cap) caused runaway compounding — worst case was 24× (3 × 2 × 4). Now the worst case is 12× (3 × 2 × 2).

**Someday flag:** For long-term goals and aspirational items (e.g. "Visit Japan"). These tasks skip staleness entirely — they stay at base weight regardless of age, so they can still appear in roulette but never dominate due to age. Mutually exclusive with high priority (they're conceptual opposites). Inspired by GTD's "Someday/Maybe" list, but kept in the main task list rather than a separate view.

**Why invisible?** Showing weights would invite meta-optimization — that's procrastination disguised as productivity.

---

## 4. Today's 5

**The core idea:** Don't ask "what should I do?" — the hardest question for ADHD.

**Instead:** Here are 5 tasks. Do what you can.

**Design details:**
- **Why 5?** Working memory holds ~4 items (Cowan, 2001). 5 feels like a real day without overwhelming.
- **Completed tasks stay visible** (strikethrough) — visible progress = dopamine
- **Progress bar** — goal gradient effect (Hull, 1932; Kivetz et al., 2006)
- **"Completing even 1 is a win!"** — reframes expectations
- **Shuffle per task** — swap what feels impossible, keep the rest
- **Tap to uncomplete** — tapping a done task restores it (no guilt, easy to fix mistakes)
- **Bottom sheet for actions** — tap any task to choose: In progress / Done today / Done for good!
- **Fresh set each day** — no guilt carryover

---

## 5. Scheduled Priorities (Day-Level Nudges)

**The problem:** Users have recurring rhythms — "work stuff Mon–Fri", "side project on weekends" — but traditional scheduling (cron rules, intervals, time-of-day) is an executive function tax.

**Our approach:** Tap a task → Schedule → toggle day-of-week chips. That's it.

| Design choice | Why |
|---|---|
| Day chips, not intervals | "Every Monday" is one tap. "Every 3 days" requires mental arithmetic. |
| Weight boost (×2.5), not guarantee | Keeps the roulette spirit — scheduled tasks *float up*, not dominate. No broken promise if they don't appear. |
| No time-of-day | Time estimation is the hardest ADHD skill (Barkley, 2012). Days are coarse enough to be safe. |
| Propagation through parent tasks | Schedule a project, all its leaf tasks get boosted. One decision covers many tasks. |
| Override replaces inheritance | A child with its own schedule ignores ancestors. Removing the child's schedule restores inheritance. No flag needed — presence of schedule rows = override. |
| Inherited days shown dimmed | The dialog shows what a task inherits (non-interactive chips), with a hint to tap to override. Clear visual distinction between "I chose this" and "I got this from a parent." |
| No "missed schedule" feedback | Missing a Tuesday schedule has zero consequence. No streak, no badge, no guilt. |

**ADHD rationale:** This is *intention setting*, not *obligation creation*. The user says "I'd like to work on X on Mondays" — the system responds by gently surfacing X more often on Mondays. If Monday passes without X, nothing happens. Compare this to calendar apps that create overdue items and guilt cycles.

**Inheritance model:** Schedules propagate downward through the DAG — schedule a project, and all its leaf tasks float up on that day. But if a child task has its own schedule, it acts as a "barrier": it overrides the parent's schedule entirely. This is implicit (no toggle or flag) — if you've set days on a task, those are *your* days. Delete them, and the parent's schedule flows through again. This keeps the mental model simple: "my schedule wins; no schedule = use parent's."

---

## What We Deliberately Avoid

| Anti-Pattern | Why It Hurts | Our Alternative |
|---|---|---|
| Streaks | Breaking = shame spiral | Cumulative counts only |
| Overdue badges | Amplifies avoidance | Tasks just reappear |
| Complex config | Executive function tax | Sensible defaults |
| Full calendar scheduling | Time estimation + config overhead | Day-chip scheduling (§5) |
| Leaderboards | External pressure = anxiety | Private, personal |
| Difficulty ratings | Triggers effort avoidance | Removed — was rarely used |
| Detailed stats | Meta-work, not real work | Simple progress bar |
| Complex repeating rules | Cron-like config, guilt on miss | Day chips + "Done today" |

---

## Apps We Studied

- **Goblin Tools** — Don't ask users to estimate effort
- **Llama Life** — Separating "working on" from "done"
- **Tiimo** — Gentle recurrence without guilt
- **Finch** — Reward any engagement, not just completion
- **Habitica** (counter-example) — Streak punishment can harm ADHD users
- **Todoist** (counter-example) — Karma + overdue = anxiety

---

## References

> **Note:** Links removed intentionally — some DOIs were AI-generated and may be inaccurate. Verify before citing in academic work.

1. Amabile & Kramer (2011). *The Progress Principle*. HBR Press.
2. Barkley (1997). Behavioral inhibition, sustained attention, and executive functions. *Psychological Bulletin*.
3. Barkley (2012). *Executive Functions*. Guilford Press.
4. Barkley (2015). *ADHD: A Handbook for Diagnosis and Treatment* (4th ed.). Guilford.
5. Cialdini (2006). *Influence: The Psychology of Persuasion*. Harper Business.
6. Cowan (2001). The magical number 4 in short-term memory. *Behavioral and Brain Sciences*.
7. Hull (1932). The goal-gradient hypothesis. *Psychological Review*.
8. Kivetz, Urminsky, & Zheng (2006). The goal-gradient hypothesis resurrected. *J. Marketing Research*.
9. Masicampo & Baumeister (2011). Consider it done! Plan making can eliminate the cognitive effects of unfulfilled goals. *J. Personality and Social Psychology*.
10. Ovsiankina (1928). Die Wiederaufnahme unterbrochener Handlungen. *Psychologische Forschung*.
11. Shaw, Stringaris, Nigg, & Leibenluft (2014). Emotion dysregulation in ADHD. *Am. J. Psychiatry*.
12. Volkow et al. (2009). Dopamine reward pathway in ADHD. *JAMA*.
