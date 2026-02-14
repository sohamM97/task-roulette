# Design Psychology: ADHD-Friendly Task System

> **TL;DR:** Every feature reduces decisions. No streaks. No guilt. No punishment. Just gentle nudges and easy wins.

---

## The One Rule

**If it makes the user think more, it's wrong.**

ADHD = impaired executive function = the brain's "manager" is overloaded. Every unnecessary choice taxes it further.

---

## 1. Quick Task Toggle (replaces Difficulty)

**Old:** 3-level difficulty (Easy/Medium/Hard)
**New:** Binary lightning bolt (quick / normal)

**Why the old way was bad:**
- Estimating effort *is* an executive function — the exact thing ADHD impairs
- "Hard" label triggers effort avoidance (Barkley, 2015)
- 3 effort levels = open-ended evaluation, which triggers ADHD decision paralysis (Barkley, 1997)

**Why the new way works:**
- "Is this quick?" — yes or no, no judgment needed
- Quick tasks build momentum (Task Snowball Method)
- Not required at creation — set it later, or never

---

## 2. Three Ways to Finish (replaces explicit repeating)

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
- No explicit schedules (daily/weekly/monthly) — reminders will come later as a separate feature

---

## 3. Weighted Random

**Same shuffle button. Smarter picks. Zero extra decisions.**

| Factor | Weight | Why |
|--------|--------|-----|
| High priority | 3x | User said it matters |
| Quick task | 1.5x | Easy win = momentum |
| Started | 2x | Commitment consistency (Cialdini, 2006) |
| Stale (per day untouched) | +10%, max 4x | Gentle rescue from neglect |
| New (< 3 days) | 1.3x | Capitalize on initial enthusiasm |

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

## What We Deliberately Avoid

| Anti-Pattern | Why It Hurts | Our Alternative |
|---|---|---|
| Streaks | Breaking = shame spiral | Cumulative counts only |
| Overdue badges | Amplifies avoidance | Tasks just reappear |
| Complex config | Executive function tax | Sensible defaults |
| Calendar scheduling | Requires time estimation | "Today's 5" |
| Leaderboards | External pressure = anxiety | Private, personal |
| Difficulty ratings | Triggers effort avoidance | Quick/normal toggle |
| Detailed stats | Meta-work, not real work | Simple progress bar |
| Explicit repeating | Config overhead, guilt on miss | Implicit via "Done today" |

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
