# Fiberco AU East Prod 01

Production infrastructure for Fiberco — Docker-based multi-project hosting with basecamp methodology.

## Quick Start (New VM)

```bash
# 1. Clone the repo
git clone https://github.com/jberry-cloudspace/fiberco-au-east-prod-01.git
cd fiberco-au-east-prod-01

# 2. Run bootstrap (installs Docker, Node, Claude Code, clones basecamp, starts everything)
bin/bootstrap

# 3. Log out and back in for docker group, then:
source ~/.bashrc
gh auth login
tracker board
project list
```

## What bootstrap does

1. Installs system packages (curl, git, jq, postgresql-client, etc.)
2. Installs Docker (if not present)
3. Installs Node.js 22 LTS (if not present)
4. Installs Claude Code globally (if not present)
5. Installs GitHub CLI (if not present)
6. Clones basecamp into `basecamp/` (or pulls latest)
7. Adds `bin/` to PATH and symlinks the tracker CLI
8. Creates the `fiberco-internal` Docker network
9. Builds the base image and starts all containers (tracker, nginx, projects)

## Projects

| Project | Domain | Description |
|---------|--------|-------------|
| fiberco-website | fiberco.com.au | Public website |
| fiberco-interact | interact.fiberco.com.au | Internal OSS/BSS platform |
| fiberco-naf | naf.fiberco.com.au | G-NAF address database + API |
| fiberco-portal | portal.fiberco.com.au | Partner portal |
| fiberco-uploads | uploads.fiberco.com.au | File upload service |

## CLI Tools

| Command | Description |
|---------|-------------|
| `project create <name>` | Create a new project with full basecamp integration |
| `project list` | List all projects and their status |
| `project shell <name>` | Shell into a project container |
| `project start-all` | Start nginx, tracker, and all projects |
| `tracker board` | View all tracked work |
| `tracker session-handoff <project>` | Get context from previous sessions |

## Creating New Projects

```bash
project create fiberco-newname --domain newname.fiberco.com.au --description "What it does"
```

See `playbooks/new-project-setup/PLAYBOOK.md` for the full checklist.

## Methodology

All development follows the **Basecamp** framework — structured playbooks for brainstorming, planning, TDD, code review, and deployment. See `basecamp/README.md`.
