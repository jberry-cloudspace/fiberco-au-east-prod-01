# Fiberco AU East Prod 01

## Project Overview
Production infrastructure and website project for Fiberco AU East region.
Docker-based multi-project hosting with isolated containers per project.

## Basecamp — MANDATORY
This project uses Basecamp, a structured development methodology. **Every session, every task, every project.**
- Core playbooks: `basecamp/playbooks/` (auto-loaded via session hook)
- Fiberco playbooks: `playbooks/` (custom to this infrastructure)
- Invoke the Playbook tool before any work. No exceptions.

## Project Tracker — MANDATORY
All work MUST be tracked. Before starting any work:
1. Run `tracker board` to see current state
2. If resuming, run `tracker session-handoff <project-name>` for context
3. Create or pick a task, then `tracker session-start <code> "<objective>"`
4. During work, update session state with decisions, completions, blockers
5. Before ending, log next steps: `tracker session-update <code> --next "..."`

See `playbooks/project-tracking/PLAYBOOK.md` for full protocol.

## Creating New Projects
New projects MUST be created using the `project create` command and follow the full setup checklist.
See `playbooks/new-project-setup/PLAYBOOK.md` for the complete protocol.

```bash
project create fiberco-newname --domain newname.fiberco.com.au --description "What it does"
```

This automatically generates:
- Docker container + database
- CLAUDE.md with basecamp/tracker integration
- Nginx reverse proxy config
- Prints remaining manual steps (DNS, SSL, tracker registration, root CLAUDE.md update)

## Tools
| Tool | Purpose | Location |
|------|---------|----------|
| `project` | Container lifecycle (create, up, down, shell, db, logs) | `bin/project` |
| `tracker` | Task tracking, session handoff, time logging | `bin/tracker` |
| `bin/renew-certs` | SSL certificate provisioning and renewal | `bin/renew-certs` |
| `bin/gnaf-update` | G-NAF address database quarterly update | `bin/gnaf-update` |

## Projects
| Project | Container | Domain |
|---------|-----------|--------|
| fiberco-website | fiberco-website-app | fiberco.com.au |
| fiberco-interact | fiberco-interact-app | interact.fiberco.com.au |
| fiberco-naf | fiberco-naf-app | naf.fiberco.com.au |
| fiberco-portal | fiberco-portal-app | portal.fiberco.com.au |
| fiberco-uploads | fiberco-uploads-app | uploads.fiberco.com.au |

## Infrastructure
- **Host VM:** fiberco-au-east-prod-1 (Ubuntu 24.04, 8 cores, 16GB RAM)
- **Docker:** Each project = app container + postgres DB
- **Networking:** `fiberco-internal` shared network (app-to-app only, DBs isolated)
- **Reverse proxy:** nginx on ports 80/443, subdomain routing + SSL (Let's Encrypt)
- **Tracker DB:** fiberco-tracker-db (shared PostgreSQL for project tracking)
- **Uploads:** IP-restricted to Hypernet subnet (165.101.9.0/24)
