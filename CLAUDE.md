# FiberCo AU East Prod 01

## Project Overview
Production infrastructure and website project for FiberCo AU East region.
Docker-based multi-project hosting with isolated containers per project.

## Superpowers
This project uses [superpowers](https://github.com/obra/superpowers) for structured development workflows.
Skills are available in `superpowers/skills/` and custom FiberCo skills in `skills/`.

## Custom Skills
FiberCo-specific skills live in `skills/` at the project root. These follow the same
SKILL.md format as superpowers but are tailored to FiberCo operations and infrastructure.

## Project Tracker
All work MUST be tracked. Before starting any work:
1. Run `tracker board` to see current state
2. If resuming, run `tracker session-handoff <project-name>` for context
3. Create or pick a task, then `tracker session-start <code> "<objective>"`
4. During work, update session state with decisions, completions, blockers
5. Before ending, log next steps: `tracker session-update <code> --next "..."`

See `skills/project-tracking/SKILL.md` for full protocol.
See `tracker help` for all commands.

## Projects
| Project | Container | Domain |
|---------|-----------|--------|
| fiberco-website | fiberco-website-app | fiberco.com.au |
| fiberco-interact | fiberco-interact-app | interact.fiberco.com.au |
| fiberco-naf | fiberco-naf-app | naf.fiberco.com.au |
| fiberco-portal | fiberco-portal-app | portal.fiberco.com.au |

## Infrastructure
- **Host VM:** fiberco-au-east-prod-1 (Ubuntu 24.04, 8 cores, 16GB RAM)
- **Docker:** Each project = app container + postgres DB
- **Networking:** `fiberco-internal` shared network (app-to-app only, DBs isolated)
- **Reverse proxy:** nginx on ports 80/443, subdomain routing
- **Tracker DB:** fiberco-tracker-db (shared PostgreSQL for project tracking)
