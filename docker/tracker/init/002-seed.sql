-- Seed projects (our 4 containers)
INSERT INTO projects (name, display_name, container_name, domain, description) VALUES
    ('fiberco-website', 'FiberCo Website', 'fiberco-website-app', 'fiberco.com.au', 'Public-facing FiberCo website'),
    ('fiberco-interact', 'FiberCo Interact', 'fiberco-interact-app', 'interact.fiberco.com.au', 'Internal business management platform — OLTs, dwellings, networking, service assurance, billing, ticketing'),
    ('fiberco-naf', 'FiberCo NAF', 'fiberco-naf-app', 'naf.fiberco.com.au', 'Geocoded National Address File — comprehensive database of every Australian physical address'),
    ('fiberco-portal', 'FiberCo Portal', 'fiberco-portal-app', 'portal.fiberco.com.au', 'Partner portal — service ordering, subscription management for clients and partners'),
    ('infrastructure', 'Infrastructure', NULL, NULL, 'Host VM, Docker, nginx, tracker — cross-cutting infrastructure tasks');

-- Seed common labels
INSERT INTO labels (name, color) VALUES
    ('security', '#EF4444'),
    ('performance', '#F59E0B'),
    ('tech-debt', '#6B7280'),
    ('ux', '#8B5CF6'),
    ('api', '#3B82F6'),
    ('database', '#10B981'),
    ('devops', '#F97316'),
    ('documentation', '#6366F1'),
    ('urgent', '#DC2626'),
    ('good-first-task', '#22C55E');
