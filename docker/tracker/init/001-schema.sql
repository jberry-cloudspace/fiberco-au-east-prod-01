-- FiberCo Project Tracker Schema

-- Sequences
CREATE SEQUENCE task_code_seq START 1;

-- Enums
CREATE TYPE task_type AS ENUM ('feature', 'bug', 'change');
CREATE TYPE task_status AS ENUM ('triage', 'backlog', 'todo', 'in_progress', 'in_review', 'done', 'cancelled');
CREATE TYPE task_priority AS ENUM ('p0', 'p1', 'p2', 'p3');
CREATE TYPE relationship_type AS ENUM ('blocks', 'is_blocked_by', 'relates_to', 'duplicates');
CREATE TYPE link_type AS ENUM ('branch', 'pr', 'commit', 'deployment');

-- Projects (maps to containers)
CREATE TABLE projects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    container_name TEXT,
    domain TEXT,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Epics (feature-level grouping)
CREATE TABLE epics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id UUID REFERENCES projects(id),
    code TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL,
    description TEXT,
    status task_status NOT NULL DEFAULT 'backlog',
    priority task_priority DEFAULT 'p2',
    created_by TEXT NOT NULL DEFAULT 'system',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Labels
CREATE TABLE labels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    color TEXT DEFAULT '#6B7280'
);

-- Tasks (core tickets)
CREATE TABLE tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE DEFAULT 'FIB-' || LPAD(nextval('task_code_seq')::TEXT, 4, '0'),
    parent_id UUID REFERENCES tasks(id),
    epic_id UUID REFERENCES epics(id),
    project_id UUID REFERENCES projects(id),
    title TEXT NOT NULL,
    description TEXT,
    type task_type NOT NULL DEFAULT 'feature',
    status task_status NOT NULL DEFAULT 'triage',
    priority task_priority DEFAULT 'p2',
    assignee TEXT,
    estimate_hours DECIMAL(6,2),
    acceptance_criteria TEXT,
    branch_name TEXT,
    pr_url TEXT,
    is_ai_generated BOOLEAN DEFAULT FALSE,
    is_ai_assignable BOOLEAN DEFAULT TRUE,
    created_by TEXT NOT NULL DEFAULT 'system',
    updated_by TEXT NOT NULL DEFAULT 'system',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ
);

-- Task labels (many-to-many)
CREATE TABLE task_labels (
    task_id UUID REFERENCES tasks(id) ON DELETE CASCADE,
    label_id UUID REFERENCES labels(id) ON DELETE CASCADE,
    PRIMARY KEY (task_id, label_id)
);

-- Task relationships
CREATE TABLE task_relationships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    target_task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    type relationship_type NOT NULL,
    created_by TEXT NOT NULL DEFAULT 'system',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Task changelog (audit history)
CREATE TABLE task_changelog (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    field_name TEXT NOT NULL,
    old_value TEXT,
    new_value TEXT,
    changed_by TEXT NOT NULL,
    change_source TEXT DEFAULT 'cli',
    changed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Comments
CREATE TABLE comments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    author TEXT NOT NULL,
    body TEXT NOT NULL,
    is_ai BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Time logs
CREATE TABLE time_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    logged_by TEXT NOT NULL,
    duration_minutes INTEGER NOT NULL,
    work_date DATE NOT NULL DEFAULT CURRENT_DATE,
    note TEXT,
    is_ai BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Session logs (AI session continuity)
CREATE TABLE session_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID REFERENCES tasks(id),
    project_id UUID REFERENCES projects(id),
    session_id TEXT,
    container_name TEXT,
    objective TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    completed_items JSONB DEFAULT '[]',
    in_progress_item TEXT,
    decisions JSONB DEFAULT '[]',
    blockers JSONB DEFAULT '[]',
    next_steps JSONB DEFAULT '[]',
    key_files JSONB DEFAULT '[]',
    branch_name TEXT,
    commit_sha TEXT,
    error_state TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Dev links (branches, PRs, commits, deployments)
CREATE TABLE task_dev_links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    type link_type NOT NULL,
    url TEXT,
    ref TEXT,
    status TEXT,
    environment TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_tasks_project ON tasks(project_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_epic ON tasks(epic_id);
CREATE INDEX idx_tasks_assignee ON tasks(assignee);
CREATE INDEX idx_tasks_code ON tasks(code);
CREATE INDEX idx_changelog_task ON task_changelog(task_id);
CREATE INDEX idx_changelog_changed_at ON task_changelog(changed_at);
CREATE INDEX idx_session_logs_task ON session_logs(task_id);
CREATE INDEX idx_session_logs_project ON session_logs(project_id);
CREATE INDEX idx_session_logs_status ON session_logs(status);
CREATE INDEX idx_time_logs_task ON time_logs(task_id);
CREATE INDEX idx_comments_task ON comments(task_id);

-- Trigger to auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tasks_updated_at BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER epics_updated_at BEFORE UPDATE ON epics FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER projects_updated_at BEFORE UPDATE ON projects FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER session_logs_updated_at BEFORE UPDATE ON session_logs FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER comments_updated_at BEFORE UPDATE ON comments FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Auto-set started_at and completed_at based on status changes
CREATE OR REPLACE FUNCTION track_task_timestamps()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'in_progress' AND OLD.status != 'in_progress' AND NEW.started_at IS NULL THEN
        NEW.started_at = NOW();
    END IF;
    IF NEW.status = 'done' AND OLD.status != 'done' THEN
        NEW.completed_at = NOW();
    END IF;
    IF NEW.status != 'done' AND OLD.status = 'done' THEN
        NEW.completed_at = NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tasks_track_timestamps BEFORE UPDATE ON tasks FOR EACH ROW EXECUTE FUNCTION track_task_timestamps();
