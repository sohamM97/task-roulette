---
name: check-screenshot
description: Check Latest Screenshot. Use when the user mentions screenshots, says "look at this", or wants to show something on screen.
---

# Check Latest Screenshot

Read the most recent screenshot from the user's screenshots directory and describe what's in it.

## Arguments

- Optional: a number N to check the N most recent screenshots (default: 1).

## Workflow

1. Check auto-memory (`~/.claude/projects/-home-soham-projects-personal-app/memory/MEMORY.md`) for the screenshots directory path.
2. If not found in memory, ask the user where their screenshots are saved, then save it to memory for future use.
3. List files in the screenshots directory sorted by modification time (newest first).
4. Read the latest screenshot(s) using the Read tool (it supports images).
5. Describe what you see — focus on anything relevant to the current task or conversation.
6. If the user seems to be showing a bug or UI issue, call it out specifically.

## Rules

- If the directory is empty or doesn't exist, tell the user.
- Always mention the filename and timestamp so the user knows which screenshot you're looking at.
- Don't make assumptions about what the user wants — describe what you see and ask if they need something specific.
