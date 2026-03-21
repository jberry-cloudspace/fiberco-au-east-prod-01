---
name: new-project-setup
description: Use when creating a new project, adding a new container, or onboarding a new service to the Fiberco infrastructure. Ensures basecamp, tracker, nginx, SSL, and all tooling are configured from day one.
---

# New Project Setup

## Overview

Every new Fiberco project MUST be fully integrated with the basecamp framework, project tracker, and infrastructure tooling before any development begins. A project that skips setup steps will drift from the workflow and create problems later.

## Iron Law

**NO PROJECT WITHOUT FULL BASECAMP INTEGRATION.**

## Checklist

You MUST create a task for each of these items and work through them sequentially:

1. **Brainstorm the project** — use the brainstorming playbook to define what this project does, its domain, and how it fits with existing projects
2. **Create the container** — run `project create <name>` to scaffold Docker, database, and networking
3. **Verify CLAUDE.md** — confirm the generated `docker/projects/<name>/CLAUDE.md` exists and is accurate; customise the project-specific section
4. **Register with tracker** — add the project to the tracker database seed and create the initial task
5. **Configure nginx** — create `docker/nginx/conf.d/<name>.conf` with the subdomain routing
6. **Provision SSL** — run `bin/renew-certs` to obtain Let's Encrypt certificate for the new domain
7. **Configure DNS** — add the subdomain A record in Cloudflare pointing to the server IP
8. **Update root CLAUDE.md** — add the new project to the projects table in the repo root CLAUDE.md
9. **Verify end-to-end** — confirm the container is running, nginx routes correctly, HTTPS works, tracker has the project, and `tracker board --project <name>` shows clean state
10. **Start development** — invoke the brainstorming playbook for the first feature

## Container Creation

```bash
# Creates container, database, .env, CLAUDE.md, and starts services
project create fiberco-newproject
```

This scaffolds:
- `docker/projects/fiberco-newproject/docker-compose.yml`
- `docker/projects/fiberco-newproject/.env`
- `docker/projects/fiberco-newproject/CLAUDE.md`

## CLAUDE.md Requirements

Every project container MUST have a `CLAUDE.md` that includes:

1. **Basecamp declaration** — states the project uses basecamp and where playbooks live
2. **Tracker requirement** — mandates `tracker board` before any work
3. **Project identity** — container name, domain, what the project does
4. **Tool references** — lists all CLI tools (`tracker`, `project`, `bin/*`)
5. **Infrastructure context** — how this project connects to others on the fiberco-internal network

The `project create` command generates this automatically from the template at `docker/project-template/CLAUDE.md.template`.

## Tracker Registration

After creating the container, register the project in the tracker:

```sql
-- Add to docker/tracker/init/002-seed.sql
INSERT INTO projects (name, display_name, container_name, domain, description) VALUES
    ('fiberco-newproject', 'Fiberco New Project', 'fiberco-newproject-app', 'newproject.fiberco.com.au', 'Description here');
```

Or if the tracker is already running:

```bash
docker exec fiberco-tracker-db psql -U tracker -d tracker -c "
INSERT INTO projects (name, display_name, container_name, domain, description) VALUES
    ('fiberco-newproject', 'Fiberco New Project', 'fiberco-newproject-app', 'newproject.fiberco.com.au', 'Description here');
"
```

## Nginx Configuration

Create `docker/nginx/conf.d/fiberco-newproject.conf`:

```nginx
server {
    listen 443 ssl;
    server_name newproject.fiberco.com.au;

    ssl_certificate /etc/letsencrypt/live/newproject.fiberco.com.au/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/newproject.fiberco.com.au/privkey.pem;

    location / {
        proxy_pass http://fiberco-newproject-app:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    server_name newproject.fiberco.com.au;
    return 301 https://$host$request_uri;
}
```

Then reload: `project nginx-reload`

## Tools Reference

Every project has access to these tools — agents and developers must know about them:

| Tool | Purpose | Usage |
|------|---------|-------|
| `project` | Container lifecycle (create, up, down, shell, db, logs) | `project <cmd> <name>` |
| `tracker` | Task tracking, session handoff, time logging | `tracker <cmd>` |
| `bin/renew-certs` | SSL certificate provisioning and renewal | `bin/renew-certs` |
| `bin/gnaf-update` | G-NAF address database quarterly update | `bin/gnaf-update` |
| Basecamp playbooks | Structured development methodology | Auto-loaded via session hook |
| Fiberco playbooks | Custom playbooks in `playbooks/` | Loaded via Playbook tool |

## Red Flags — STOP

- Creating a project without a CLAUDE.md
- Starting development without registering in the tracker
- Skipping nginx/SSL setup ("we'll do it later")
- Not adding the project to the root CLAUDE.md projects table
- Creating a container manually instead of using `project create`
