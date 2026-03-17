---
name: project-tracking
description: Use when starting any work session, completing tasks, encountering blockers, or when asked what was being worked on. Ensures all work is tracked in the FiberCo tracker database.
---

# Project Tracking

## Overview

All work MUST be tracked in the FiberCo tracker database via `tracker` CLI. This enables session continuity — if a session drops, the next session can resume by reading the tracker state.

## Iron Law

**NO WORK WITHOUT A TRACKED TASK.**

Starting to code without a tracker task is like committing without a message. Don't do it.

## Session Start Protocol

At the start of EVERY session, before doing any work:

1. Run `tracker board` to see the current state of all work
2. If resuming, run `tracker session-handoff <task-code>` or `tracker session-handoff <project-name>` to get context
3. Identify which task to work on (or create a new one)
4. Run `tracker session-start <task-code> "<objective>"` to begin

## During Work

- When you make a key decision: `tracker session-update <code> --decision "chose X because Y"`
- When you complete a sub-item: `tracker session-update <code> --completed "built the API endpoint"`
- When you hit a blocker: `tracker session-update <code> --blocker "dependency X not available"`
- When you encounter an error: `tracker session-update <code> --error "build fails: missing module"`
- Update what you're actively doing: `tracker session-update <code> --in-progress "writing tests for auth"`
- Log time periodically: `tracker log-time <code> <minutes> "description"`

## Session End Protocol

Before ending a session (or if you sense it may drop):

1. Update session with next steps: `tracker session-update <code> --next "implement validation logic"`
2. End the session: `tracker session-end <code>`
3. Update task status if needed: `tracker update <code> --status <new-status>`

## Creating Tasks

```bash
tracker create "Task title" --project fiberco-website --type feature --priority p1
```

Types: `feature`, `bug`, `change`
Priorities: `p0` (urgent), `p1` (high), `p2` (medium), `p3` (low)
Projects: `fiberco-website`, `fiberco-interact`, `fiberco-naf`, `fiberco-portal`, `infrastructure`

## Board View

```bash
tracker board                              # All projects
tracker board --project fiberco-website    # Single project
```

## Resuming Work

When asked "what were we working on?" or starting a new session:

```bash
tracker board                                    # See everything
tracker session-handoff fiberco-website          # Get handoff for a project
tracker session-handoff FIB-0001                 # Get handoff for a specific task
```

## Status Flow

```
triage → backlog → todo → in_progress → in_review → done
                                    ↘ cancelled
```

## Red Flags — STOP

- Starting work without running `tracker board` first
- Writing code without a task code
- Ending a session without updating next steps
- Not logging decisions that would be useful for session resumption
