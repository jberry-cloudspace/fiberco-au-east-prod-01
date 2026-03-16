# Base Dockerfile + Nginx Reverse Proxy

**Date:** 2026-03-16
**Status:** Completed

## Verification Evidence
- Base image: Claude Code 2.1.76, Node 22.22.1, Python 3.12.3, gh 2.88.1, superpowers 14 skills
- Nginx: routes to existing containers (502 when no app listening — correct), rejects unknown hosts (444), doesn't crash when containers are missing (variable-based upstreams with Docker DNS resolver)
- All containers stable, no restart loops

## Tasks
- [x] Task 1: Update Dockerfile with full dev tooling
- [x] Task 2: Update docker-compose template with ANTHROPIC_API_KEY
- [x] Task 3: Add nginx reverse proxy container
- [x] Task 4: Update bin/project with nginx commands
- [x] Task 5: Verified end-to-end
