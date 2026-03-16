# Shared Internal Network for Inter-Project Communication

**Date:** 2026-03-16
**Status:** Completed

## Goal
Allow app containers from different projects to communicate over a shared Docker network, without exposing databases or using the public internet.

## Design
- Create a persistent `fiberco-internal` Docker network
- App containers join both their project network AND the shared network
- DB containers stay on project network only
- App containers are reachable by other apps via `<project-name>-app` hostname

## Tasks

- [x] Task 1: Create the shared `fiberco-internal` network
  - Add to `bin/project` — ensure network exists on create/up
  - One-liner: `docker network create fiberco-internal` (if not exists)

- [x] Task 2: Update docker-compose template to attach app to shared network
  - Add `fiberco-internal` as an external network in the template
  - Attach only the `app` service to it (not `db`)

- [x] Task 3: Update `bin/project` create command
  - Ensure `fiberco-internal` network is created before `docker compose up`

- [x] Task 4: Verify — spin up two test projects and confirm they can reach each other
  - Create test-a and test-b
  - From test-a-app, ping/curl test-b-app
  - Confirm test-a-app cannot reach test-b-db
  - Destroy test projects
