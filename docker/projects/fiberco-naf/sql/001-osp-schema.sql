-- =============================================================================
-- FiberCo OSP (Outside Plant) Asset Management Schema
-- PostgreSQL 16 + PostGIS 3.5
-- =============================================================================
--
-- Coordinate Reference System: GDA2020 Geographic (EPSG:7844)
--   - All geometries stored in EPSG:7844 (latitude/longitude on GRS80 ellipsoid)
--   - For distance/area calculations, transform to the appropriate MGA zone:
--       EPSG:7854 = MGA2020 Zone 54 (138E-144E)
--       EPSG:7855 = MGA2020 Zone 55 (144E-150E) -- Melbourne, Canberra, Hobart
--       EPSG:7856 = MGA2020 Zone 56 (150E-156E) -- Sydney, Brisbane
--
-- Entity Hierarchy:
--   Route -> Duct Segment -> Subduct -> Cable -> Tube/Buffer -> Fiber
--   Route passes through Pits/Manholes (point assets)
--   Splice Closures sit at Pits/Manholes and join cables
--   Splice Trays within closures hold individual fiber splices
--   Poles carry aerial cables between spans
--
-- Design Principles:
--   1. Separate geometry (GIS) from logical connectivity (splicing/tracing)
--   2. Reference tables for types/statuses keep data clean
--   3. Fiber tracing is computed via recursive queries across splice_connection
--   4. Duct occupancy is derived from cable_in_duct, never stored as a counter
--   5. All assets carry lifecycle fields (status, install_date, decommission_date)
--   6. Owner/operator fields support both own-build and leased infrastructure
--
-- =============================================================================

-- Ensure PostGIS is available
CREATE EXTENSION IF NOT EXISTS postgis;

-- All OSP tables live in their own schema to separate from G-NAF address data
CREATE SCHEMA IF NOT EXISTS osp;

-- =============================================================================
-- SECTION 1: REFERENCE / LOOKUP TABLES
-- =============================================================================

-- Asset lifecycle status (applies to all physical assets)
CREATE TABLE osp.asset_status (
    code        TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT
);

INSERT INTO osp.asset_status (code, label, description) VALUES
    ('PLANNED',         'Planned',          'Design/planning phase, not yet built'),
    ('IN_CONSTRUCTION', 'In Construction',  'Currently being installed'),
    ('ACTIVE',          'Active',           'Installed and in service'),
    ('MAINTENANCE',     'Under Maintenance','Temporarily out of service for maintenance'),
    ('DECOMMISSIONED',  'Decommissioned',   'Permanently removed from service'),
    ('ABANDONED',       'Abandoned',        'Left in place but no longer used');

-- Duct material types
CREATE TABLE osp.duct_material (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.duct_material (code, label) VALUES
    ('HDPE',    'High-Density Polyethylene'),
    ('PVC',     'Polyvinyl Chloride'),
    ('GI',      'Galvanised Iron'),
    ('STEEL',   'Steel'),
    ('CONCRETE','Concrete'),
    ('OTHER',   'Other');

-- Duct size (outer diameter in mm, standard Australian sizes)
CREATE TABLE osp.duct_size (
    code       TEXT PRIMARY KEY,
    label      TEXT NOT NULL,
    od_mm      NUMERIC NOT NULL,  -- outer diameter
    id_mm      NUMERIC NOT NULL   -- inner diameter
);

INSERT INTO osp.duct_size (code, label, od_mm, id_mm) VALUES
    ('SD_7',    'Subduct 7mm',     7,    5),
    ('SD_10',   'Subduct 10mm',    10,   7),
    ('SD_12',   'Subduct 12mm',    12,   10),
    ('SD_14',   'Subduct 14mm',    14,   10),
    ('SD_16',   'Subduct 16mm',    16,   12),
    ('SD_20',   'Subduct 20mm',    20,   16),
    ('SD_25',   'Subduct 25mm',    25,   20),
    ('D_50',    'Duct 50mm',       50,   41),
    ('D_96',    'Duct 96mm',       96,   86),
    ('D_100',   'Duct 100mm',      100,  90),
    ('D_110',   'Duct 110mm',      110,  96),
    ('D_150',   'Duct 150mm',      150,  130),
    ('D_200',   'Duct 200mm',      200,  176);

-- Cable types
CREATE TABLE osp.cable_type (
    code        TEXT PRIMARY KEY,
    label       TEXT NOT NULL,
    description TEXT
);

INSERT INTO osp.cable_type (code, label, description) VALUES
    ('LOOSE_TUBE',    'Loose Tube',         'Standard loose tube fiber cable'),
    ('RIBBON',        'Ribbon',             'Ribbon fiber cable (high density)'),
    ('MICRO',         'Micro Cable',        'Micro/blown fiber cable'),
    ('FLAT_DROP',     'Flat Drop',          'Flat drop cable for premises entry'),
    ('ROUND_DROP',    'Round Drop',         'Round drop cable for premises entry'),
    ('AERIAL',        'Aerial/Figure-8',    'Self-supporting aerial cable'),
    ('ADSS',          'ADSS',               'All-Dielectric Self-Supporting'),
    ('ARMOURED',      'Armoured',           'Steel/aluminium armoured cable'),
    ('DIRECT_BURIED', 'Direct Buried',      'Cable rated for direct burial'),
    ('INDOOR',        'Indoor',             'Indoor rated cable');

-- Fiber mode
CREATE TABLE osp.fiber_mode (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.fiber_mode (code, label) VALUES
    ('SM',    'Single Mode (OS2/G.652D)'),
    ('MM50',  'Multi Mode 50um (OM3/OM4)'),
    ('MM62',  'Multi Mode 62.5um (OM1/OM2)');

-- Pit/manhole types (Australian terminology)
CREATE TABLE osp.pit_type (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.pit_type (code, label) VALUES
    ('P0',        'Pit Type 0 (small/micro)'),
    ('P1',        'Pit Type 1'),
    ('P2',        'Pit Type 2'),
    ('P3',        'Pit Type 3'),
    ('P4',        'Pit Type 4 (large)'),
    ('MANHOLE',   'Manhole'),
    ('HANDHOLE',  'Handhole'),
    ('VAULT',     'Vault'),
    ('CABINET',   'Cabinet/Pillar'),
    ('PEDESTAL',  'Pedestal'),
    ('BUILDING',  'Building Entry Point');

-- Splice closure types
CREATE TABLE osp.closure_type (
    code           TEXT PRIMARY KEY,
    label          TEXT NOT NULL,
    max_trays      INTEGER,
    max_splices    INTEGER
);

INSERT INTO osp.closure_type (code, label, max_trays, max_splices) VALUES
    ('INLINE_12',     'Inline 12-fiber',      1,    12),
    ('INLINE_24',     'Inline 24-fiber',      2,    24),
    ('DOME_48',       'Dome 48-fiber',        4,    48),
    ('DOME_96',       'Dome 96-fiber',        8,    96),
    ('DOME_144',      'Dome 144-fiber',       12,   144),
    ('DOME_288',      'Dome 288-fiber',       24,   288),
    ('DOME_576',      'Dome 576-fiber',       48,   576),
    ('HORIZONTAL_96', 'Horizontal 96-fiber',  8,    96),
    ('HORIZONTAL_144','Horizontal 144-fiber', 12,   144),
    ('HORIZONTAL_288','Horizontal 288-fiber', 24,   288),
    ('WALL_MOUNT',    'Wall Mount',           4,    48),
    ('FDH_72',        'FDH 72-port',         NULL,  72),
    ('FDH_144',       'FDH 144-port',        NULL,  144),
    ('FDH_288',       'FDH 288-port',        NULL,  288);

-- Splice method
CREATE TABLE osp.splice_method (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.splice_method (code, label) VALUES
    ('FUSION',      'Fusion Splice'),
    ('MECHANICAL',  'Mechanical Splice'),
    ('CONNECTOR',   'Connectorised (patch)');

-- Pole types
CREATE TABLE osp.pole_type (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.pole_type (code, label) VALUES
    ('TIMBER',    'Timber Pole'),
    ('STEEL',     'Steel Pole'),
    ('CONCRETE',  'Concrete Pole'),
    ('COMPOSITE', 'Composite/FRP Pole'),
    ('MONOPOLE',  'Monopole');

-- Ownership classification
CREATE TABLE osp.ownership_type (
    code  TEXT PRIMARY KEY,
    label TEXT NOT NULL
);

INSERT INTO osp.ownership_type (code, label) VALUES
    ('OWN',       'FiberCo Owned'),
    ('LEASED',    'Leased from Third Party'),
    ('IRU',       'Indefeasible Right of Use'),
    ('COLOC',     'Co-location / Shared'),
    ('CUSTOMER',  'Customer Owned');


-- =============================================================================
-- SECTION 2: ROUTE NETWORK (the physical paths assets follow)
-- =============================================================================

-- A route is a named path between two points (e.g., "Sydney CBD to Parramatta backbone")
-- Routes are composed of route_segments that run pit-to-pit
CREATE TABLE osp.route (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    description     TEXT,
    route_type      TEXT NOT NULL CHECK (route_type IN ('BACKBONE', 'DISTRIBUTION', 'DROP', 'LATERAL', 'BACKHAUL')),
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    ownership       TEXT NOT NULL DEFAULT 'OWN' REFERENCES osp.ownership_type(code),
    owner_name      TEXT,                   -- third-party owner if not FiberCo
    total_length_m  NUMERIC,                -- computed from geometry, cached
    geom            GEOMETRY(MultiLineString, 7844),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_route_geom ON osp.route USING GIST (geom);
CREATE INDEX idx_route_status ON osp.route (status);
CREATE INDEX idx_route_type ON osp.route (route_type);


-- =============================================================================
-- SECTION 3: POINT ASSETS (Pits, Manholes, Poles, Buildings)
-- =============================================================================

-- Pits and manholes: underground access points where ducts meet
CREATE TABLE osp.pit (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,               -- e.g., "PIT-SYD-001234"
    pit_type        TEXT NOT NULL REFERENCES osp.pit_type(code),
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    ownership       TEXT NOT NULL DEFAULT 'OWN' REFERENCES osp.ownership_type(code),
    owner_name      TEXT,
    depth_mm        INTEGER,                     -- depth below surface
    material        TEXT,
    lid_type        TEXT,                         -- e.g., 'H20', 'D400' (load rating)
    address_detail_pid TEXT,                      -- FK to G-NAF address if near a property
    install_date    DATE,
    decommission_date DATE,
    notes           TEXT,
    geom            GEOMETRY(Point, 7844) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pit_geom ON osp.pit USING GIST (geom);
CREATE INDEX idx_pit_type ON osp.pit (pit_type);
CREATE INDEX idx_pit_status ON osp.pit (status);
CREATE INDEX idx_pit_name ON osp.pit (name);

-- Poles: aerial cable support structures
CREATE TABLE osp.pole (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    pole_type       TEXT NOT NULL REFERENCES osp.pole_type(code),
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    ownership       TEXT NOT NULL DEFAULT 'OWN' REFERENCES osp.ownership_type(code),
    owner_name      TEXT,
    height_m        NUMERIC,
    class           TEXT,                         -- strength class
    install_date    DATE,
    decommission_date DATE,
    notes           TEXT,
    geom            GEOMETRY(Point, 7844) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_pole_geom ON osp.pole USING GIST (geom);
CREATE INDEX idx_pole_status ON osp.pole (status);


-- =============================================================================
-- SECTION 4: DUCT AND CONDUIT MODEL
-- =============================================================================

-- A duct_segment runs between exactly two pits (pit A -> pit B)
-- This is the physical conduit pathway underground
CREATE TABLE osp.duct_segment (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT,
    route_id        UUID REFERENCES osp.route(id),
    from_pit_id     UUID NOT NULL REFERENCES osp.pit(id),
    to_pit_id       UUID NOT NULL REFERENCES osp.pit(id),
    duct_material   TEXT NOT NULL REFERENCES osp.duct_material(code),
    duct_size       TEXT NOT NULL REFERENCES osp.duct_size(code),
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    ownership       TEXT NOT NULL DEFAULT 'OWN' REFERENCES osp.ownership_type(code),
    owner_name      TEXT,                    -- Telstra, NBN Co, Vocus, etc.
    lease_ref       TEXT,                    -- lease/IRU reference number
    lease_expiry    DATE,
    length_m        NUMERIC,                 -- physical length (may differ from geometry)
    bore_number     INTEGER DEFAULT 1,       -- which bore in a multi-bore trench
    install_date    DATE,
    decommission_date DATE,
    notes           TEXT,
    geom            GEOMETRY(LineString, 7844),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_duct_different_pits CHECK (from_pit_id != to_pit_id)
);

CREATE INDEX idx_duct_segment_geom ON osp.duct_segment USING GIST (geom);
CREATE INDEX idx_duct_segment_route ON osp.duct_segment (route_id);
CREATE INDEX idx_duct_segment_from_pit ON osp.duct_segment (from_pit_id);
CREATE INDEX idx_duct_segment_to_pit ON osp.duct_segment (to_pit_id);
CREATE INDEX idx_duct_segment_status ON osp.duct_segment (status);
CREATE INDEX idx_duct_segment_ownership ON osp.duct_segment (ownership);

-- Subducts sit inside a parent duct_segment
-- A 100mm duct might contain 4x 25mm subducts
CREATE TABLE osp.subduct (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    duct_segment_id UUID NOT NULL REFERENCES osp.duct_segment(id),
    position        INTEGER NOT NULL,        -- position within parent duct (1, 2, 3...)
    duct_size       TEXT NOT NULL REFERENCES osp.duct_size(code),
    color           TEXT,                    -- subduct color code
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_subduct_position UNIQUE (duct_segment_id, position)
);

CREATE INDEX idx_subduct_duct ON osp.subduct (duct_segment_id);


-- =============================================================================
-- SECTION 5: CABLE MODEL
-- =============================================================================

-- A cable is a physical fiber optic cable with a defined fiber count
-- It follows a path through one or more duct segments (or is aerial between poles)
CREATE TABLE osp.cable (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,               -- e.g., "C-SYD-DIST-0042"
    cable_type      TEXT NOT NULL REFERENCES osp.cable_type(code),
    fiber_mode      TEXT NOT NULL DEFAULT 'SM' REFERENCES osp.fiber_mode(code),
    fiber_count     INTEGER NOT NULL,            -- total fiber count (e.g., 12, 24, 48, 96, 144, 288)
    tube_count      INTEGER,                     -- number of buffer tubes/ribbons
    fibers_per_tube INTEGER,                     -- fibers per tube (e.g., 12)
    sheath_type     TEXT,                        -- e.g., 'PE', 'LSZH', 'PVC'
    outer_diameter_mm NUMERIC,                   -- cable OD
    manufacturer    TEXT,
    model           TEXT,
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    ownership       TEXT NOT NULL DEFAULT 'OWN' REFERENCES osp.ownership_type(code),
    owner_name      TEXT,
    install_date    DATE,
    decommission_date DATE,
    total_length_m  NUMERIC,
    route_id        UUID REFERENCES osp.route(id),
    notes           TEXT,
    geom            GEOMETRY(MultiLineString, 7844),  -- full cable route geometry
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_cable_geom ON osp.cable USING GIST (geom);
CREATE INDEX idx_cable_status ON osp.cable (status);
CREATE INDEX idx_cable_route ON osp.cable (route_id);
CREATE INDEX idx_cable_name ON osp.cable (name);
CREATE INDEX idx_cable_type ON osp.cable (cable_type);

-- Cable placement: which duct segment (or subduct) contains which cable
-- A cable may traverse many duct segments; a duct segment may contain many cables
CREATE TABLE osp.cable_in_duct (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cable_id        UUID NOT NULL REFERENCES osp.cable(id),
    duct_segment_id UUID NOT NULL REFERENCES osp.duct_segment(id),
    subduct_id      UUID REFERENCES osp.subduct(id),   -- NULL if cable is directly in duct
    sequence_order  INTEGER NOT NULL,                    -- order along the cable path
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cable_duct_seq UNIQUE (cable_id, duct_segment_id, sequence_order)
);

CREATE INDEX idx_cable_in_duct_cable ON osp.cable_in_duct (cable_id);
CREATE INDEX idx_cable_in_duct_duct ON osp.cable_in_duct (duct_segment_id);
CREATE INDEX idx_cable_in_duct_subduct ON osp.cable_in_duct (subduct_id);

-- Cable on pole: aerial cable attachments
CREATE TABLE osp.cable_on_pole (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cable_id        UUID NOT NULL REFERENCES osp.cable(id),
    pole_id         UUID NOT NULL REFERENCES osp.pole(id),
    attachment_height_m NUMERIC,
    sequence_order  INTEGER NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_cable_pole_seq UNIQUE (cable_id, pole_id)
);

CREATE INDEX idx_cable_on_pole_cable ON osp.cable_on_pole (cable_id);
CREATE INDEX idx_cable_on_pole_pole ON osp.cable_on_pole (pole_id);


-- =============================================================================
-- SECTION 6: FIBER MODEL (individual fibers within cables)
-- =============================================================================

-- Buffer tubes / ribbon groups within a cable
-- A 96-fiber loose-tube cable might have 8 tubes of 12 fibers each
CREATE TABLE osp.tube (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cable_id        UUID NOT NULL REFERENCES osp.cable(id),
    tube_number     INTEGER NOT NULL,            -- 1-based position
    color           TEXT,                         -- TIA-598 color code
    fiber_count     INTEGER NOT NULL,
    tube_type       TEXT DEFAULT 'BUFFER' CHECK (tube_type IN ('BUFFER', 'RIBBON', 'MICRO_MODULE')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tube_in_cable UNIQUE (cable_id, tube_number)
);

CREATE INDEX idx_tube_cable ON osp.tube (cable_id);

-- Individual fibers within a tube
-- Each fiber has a globally unique ID and a position within its tube
CREATE TABLE osp.fiber (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cable_id        UUID NOT NULL REFERENCES osp.cable(id),
    tube_id         UUID NOT NULL REFERENCES osp.tube(id),
    fiber_number    INTEGER NOT NULL,            -- fiber number within the cable (1-288)
    fiber_in_tube   INTEGER NOT NULL,            -- position within tube (1-12)
    color           TEXT,                         -- TIA-598 color code
    fiber_mode      TEXT NOT NULL DEFAULT 'SM' REFERENCES osp.fiber_mode(code),
    status          TEXT NOT NULL DEFAULT 'ACTIVE' REFERENCES osp.asset_status(code),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_fiber_in_cable UNIQUE (cable_id, fiber_number),
    CONSTRAINT uq_fiber_in_tube UNIQUE (tube_id, fiber_in_tube)
);

CREATE INDEX idx_fiber_cable ON osp.fiber (cable_id);
CREATE INDEX idx_fiber_tube ON osp.fiber (tube_id);
CREATE INDEX idx_fiber_number ON osp.fiber (cable_id, fiber_number);
CREATE INDEX idx_fiber_status ON osp.fiber (status);


-- =============================================================================
-- SECTION 7: SPLICE CLOSURE AND SPLICING MODEL
-- =============================================================================

-- A splice closure sits at a pit/manhole and joins cables together
CREATE TABLE osp.splice_closure (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,                   -- e.g., "SC-SYD-00456"
    closure_type    TEXT NOT NULL REFERENCES osp.closure_type(code),
    pit_id          UUID REFERENCES osp.pit(id),     -- which pit it lives in
    pole_id         UUID REFERENCES osp.pole(id),    -- or which pole (aerial closures)
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    manufacturer    TEXT,
    model           TEXT,
    install_date    DATE,
    decommission_date DATE,
    notes           TEXT,
    geom            GEOMETRY(Point, 7844),           -- explicit location (may differ from pit)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_closure_location CHECK (pit_id IS NOT NULL OR pole_id IS NOT NULL)
);

CREATE INDEX idx_splice_closure_geom ON osp.splice_closure USING GIST (geom);
CREATE INDEX idx_splice_closure_pit ON osp.splice_closure (pit_id);
CREATE INDEX idx_splice_closure_pole ON osp.splice_closure (pole_id);
CREATE INDEX idx_splice_closure_status ON osp.splice_closure (status);
CREATE INDEX idx_splice_closure_name ON osp.splice_closure (name);

-- Which cables enter a splice closure
CREATE TABLE osp.closure_cable_entry (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    closure_id      UUID NOT NULL REFERENCES osp.splice_closure(id),
    cable_id        UUID NOT NULL REFERENCES osp.cable(id),
    entry_port      INTEGER NOT NULL,            -- physical port/entry number on closure
    entry_direction TEXT,                         -- e.g., 'NORTH', 'A-SIDE', 'B-SIDE'
    cable_end       TEXT NOT NULL CHECK (cable_end IN ('A', 'B')),  -- which end of cable enters
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_closure_cable UNIQUE (closure_id, cable_id, cable_end),
    CONSTRAINT uq_closure_port UNIQUE (closure_id, entry_port)
);

CREATE INDEX idx_closure_cable_entry_closure ON osp.closure_cable_entry (closure_id);
CREATE INDEX idx_closure_cable_entry_cable ON osp.closure_cable_entry (cable_id);

-- Splice trays within a closure
CREATE TABLE osp.splice_tray (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    closure_id      UUID NOT NULL REFERENCES osp.splice_closure(id),
    tray_number     INTEGER NOT NULL,
    tray_type       TEXT DEFAULT 'STANDARD',     -- STANDARD, RIBBON, etc.
    capacity        INTEGER NOT NULL DEFAULT 12, -- max splices in this tray
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_tray_in_closure UNIQUE (closure_id, tray_number)
);

CREATE INDEX idx_splice_tray_closure ON osp.splice_tray (closure_id);

-- Individual splice connections: fiber X in cable A <-> fiber Y in cable B
-- This is the core connectivity table that enables end-to-end fiber tracing
CREATE TABLE osp.splice_connection (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tray_id         UUID NOT NULL REFERENCES osp.splice_tray(id),
    position        INTEGER NOT NULL,                -- position within tray (1-12, 1-24, etc.)
    a_fiber_id      UUID NOT NULL REFERENCES osp.fiber(id),
    b_fiber_id      UUID NOT NULL REFERENCES osp.fiber(id),
    splice_method   TEXT NOT NULL DEFAULT 'FUSION' REFERENCES osp.splice_method(code),
    loss_db         NUMERIC(5,3),                    -- measured splice loss in dB
    status          TEXT NOT NULL DEFAULT 'ACTIVE' REFERENCES osp.asset_status(code),
    splice_date     DATE,
    technician      TEXT,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_splice_different_fibers CHECK (a_fiber_id != b_fiber_id),
    CONSTRAINT uq_tray_position UNIQUE (tray_id, position)
);

CREATE INDEX idx_splice_connection_tray ON osp.splice_connection (tray_id);
CREATE INDEX idx_splice_connection_a_fiber ON osp.splice_connection (a_fiber_id);
CREATE INDEX idx_splice_connection_b_fiber ON osp.splice_connection (b_fiber_id);
CREATE INDEX idx_splice_connection_status ON osp.splice_connection (status);


-- =============================================================================
-- SECTION 8: FIBER ASSIGNMENT / SERVICE ALLOCATION
-- =============================================================================

-- Tracks which fibers are assigned to which service/customer
-- A fiber may be assigned end-to-end across multiple splices
CREATE TABLE osp.fiber_assignment (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    fiber_id        UUID NOT NULL REFERENCES osp.fiber(id),
    assignment_type TEXT NOT NULL CHECK (assignment_type IN ('CUSTOMER', 'BACKHAUL', 'DARK_FIBER', 'MONITORING', 'SPARE', 'RESERVED')),
    customer_ref    TEXT,                        -- external customer/service reference
    service_ref     TEXT,                        -- service ID / circuit ID
    a_location      TEXT,                        -- human-readable A-end description
    z_location      TEXT,                        -- human-readable Z-end description
    assigned_date   DATE,
    released_date   DATE,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_fiber_assignment_fiber ON osp.fiber_assignment (fiber_id);
CREATE INDEX idx_fiber_assignment_customer ON osp.fiber_assignment (customer_ref);
CREATE INDEX idx_fiber_assignment_service ON osp.fiber_assignment (service_ref);
CREATE INDEX idx_fiber_assignment_type ON osp.fiber_assignment (assignment_type);


-- =============================================================================
-- SECTION 9: EQUIPMENT (OLTs, FDHs, ONTs, Patch Panels)
-- =============================================================================

-- Network equipment installed at sites
CREATE TABLE osp.equipment (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    equipment_type  TEXT NOT NULL CHECK (equipment_type IN (
        'OLT', 'ONT', 'ONU', 'FDH', 'PATCH_PANEL', 'OTDR', 'SPLITTER', 'WDM', 'AMPLIFIER', 'MEDIA_CONVERTER', 'SWITCH', 'OTHER'
    )),
    manufacturer    TEXT,
    model           TEXT,
    serial_number   TEXT,
    pit_id          UUID REFERENCES osp.pit(id),
    pole_id         UUID REFERENCES osp.pole(id),
    rack_location   TEXT,                    -- rack/shelf/slot position
    port_count      INTEGER,
    status          TEXT NOT NULL DEFAULT 'PLANNED' REFERENCES osp.asset_status(code),
    install_date    DATE,
    decommission_date DATE,
    notes           TEXT,
    geom            GEOMETRY(Point, 7844),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_equipment_geom ON osp.equipment USING GIST (geom);
CREATE INDEX idx_equipment_type ON osp.equipment (equipment_type);
CREATE INDEX idx_equipment_pit ON osp.equipment (pit_id);
CREATE INDEX idx_equipment_status ON osp.equipment (status);

-- Equipment ports: individual connectorised ports on equipment
CREATE TABLE osp.equipment_port (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    equipment_id    UUID NOT NULL REFERENCES osp.equipment(id),
    port_number     INTEGER NOT NULL,
    port_label      TEXT,                        -- e.g., "PON1/1", "GE0/0/1"
    connector_type  TEXT DEFAULT 'SC/APC' CHECK (connector_type IN (
        'SC/APC', 'SC/UPC', 'LC/APC', 'LC/UPC', 'FC/APC', 'FC/UPC', 'MPO', 'E2000', 'OTHER'
    )),
    fiber_id        UUID REFERENCES osp.fiber(id),  -- which fiber is patched to this port
    status          TEXT NOT NULL DEFAULT 'ACTIVE' REFERENCES osp.asset_status(code),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_equipment_port UNIQUE (equipment_id, port_number)
);

CREATE INDEX idx_equipment_port_equipment ON osp.equipment_port (equipment_id);
CREATE INDEX idx_equipment_port_fiber ON osp.equipment_port (fiber_id);

-- Splitter: models 1:N passive optical splitters
-- Placed inside FDHs or splice closures
CREATE TABLE osp.splitter (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT,
    split_ratio     TEXT NOT NULL,               -- e.g., '1:8', '1:16', '1:32'
    splitter_type   TEXT DEFAULT 'PLC' CHECK (splitter_type IN ('PLC', 'FBT')),
    input_fiber_id  UUID REFERENCES osp.fiber(id),
    equipment_id    UUID REFERENCES osp.equipment(id),  -- FDH or closure it sits in
    status          TEXT NOT NULL DEFAULT 'ACTIVE' REFERENCES osp.asset_status(code),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_splitter_equipment ON osp.splitter (equipment_id);
CREATE INDEX idx_splitter_input_fiber ON osp.splitter (input_fiber_id);

-- Splitter output ports
CREATE TABLE osp.splitter_port (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    splitter_id     UUID NOT NULL REFERENCES osp.splitter(id),
    port_number     INTEGER NOT NULL,
    output_fiber_id UUID REFERENCES osp.fiber(id),
    status          TEXT NOT NULL DEFAULT 'ACTIVE' REFERENCES osp.asset_status(code),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_splitter_port UNIQUE (splitter_id, port_number)
);

CREATE INDEX idx_splitter_port_splitter ON osp.splitter_port (splitter_id);
CREATE INDEX idx_splitter_port_fiber ON osp.splitter_port (output_fiber_id);


-- =============================================================================
-- SECTION 10: AUDIT / HISTORY
-- =============================================================================

-- Generic audit log for tracking changes to any OSP asset
CREATE TABLE osp.audit_log (
    id              BIGSERIAL PRIMARY KEY,
    table_name      TEXT NOT NULL,
    record_id       UUID NOT NULL,
    action          TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
    changed_fields  JSONB,
    changed_by      TEXT,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_audit_log_table_record ON osp.audit_log (table_name, record_id);
CREATE INDEX idx_audit_log_changed_at ON osp.audit_log (changed_at);


-- =============================================================================
-- SECTION 11: VIEWS FOR COMMON QUERIES
-- =============================================================================

-- View: Duct occupancy (cables per duct segment, with capacity utilisation)
CREATE OR REPLACE VIEW osp.v_duct_occupancy AS
SELECT
    ds.id AS duct_segment_id,
    ds.name AS duct_name,
    ds.duct_size,
    dsz.id_mm AS duct_inner_diameter_mm,
    ds.from_pit_id,
    fp.name AS from_pit_name,
    ds.to_pit_id,
    tp.name AS to_pit_name,
    ds.ownership,
    ds.owner_name,
    ds.status,
    COUNT(cid.id) AS cable_count,
    STRING_AGG(c.name, ', ' ORDER BY c.name) AS cable_names,
    SUM(c.outer_diameter_mm) AS total_cable_od_mm,
    -- Rough area-based fill ratio (cable ODs vs duct ID)
    CASE
        WHEN dsz.id_mm > 0 THEN
            ROUND((SUM(POWER(c.outer_diameter_mm / 2.0, 2)) / POWER(dsz.id_mm / 2.0, 2)) * 100, 1)
        ELSE NULL
    END AS fill_ratio_pct
FROM osp.duct_segment ds
    JOIN osp.duct_size dsz ON ds.duct_size = dsz.code
    JOIN osp.pit fp ON ds.from_pit_id = fp.id
    JOIN osp.pit tp ON ds.to_pit_id = tp.id
    LEFT JOIN osp.cable_in_duct cid ON ds.id = cid.duct_segment_id
    LEFT JOIN osp.cable c ON cid.cable_id = c.id
GROUP BY ds.id, ds.name, ds.duct_size, dsz.id_mm,
         ds.from_pit_id, fp.name, ds.to_pit_id, tp.name,
         ds.ownership, ds.owner_name, ds.status;

-- View: All fibers in a cable (with tube and color info)
CREATE OR REPLACE VIEW osp.v_cable_fibers AS
SELECT
    c.id AS cable_id,
    c.name AS cable_name,
    c.fiber_count AS cable_fiber_count,
    c.cable_type,
    t.tube_number,
    t.color AS tube_color,
    t.tube_type,
    f.id AS fiber_id,
    f.fiber_number,
    f.fiber_in_tube,
    f.color AS fiber_color,
    f.status AS fiber_status,
    fa.assignment_type,
    fa.customer_ref,
    fa.service_ref
FROM osp.cable c
    JOIN osp.tube t ON c.id = t.cable_id
    JOIN osp.fiber f ON t.id = f.tube_id
    LEFT JOIN osp.fiber_assignment fa ON f.id = fa.fiber_id AND fa.released_date IS NULL
ORDER BY c.name, f.fiber_number;

-- View: Splice closure summary (cables entering, splice count)
CREATE OR REPLACE VIEW osp.v_closure_summary AS
SELECT
    sc.id AS closure_id,
    sc.name AS closure_name,
    sc.closure_type,
    ct.max_splices AS closure_capacity,
    p.name AS pit_name,
    sc.status,
    COUNT(DISTINCT cce.cable_id) AS cable_count,
    STRING_AGG(DISTINCT cab.name, ', ' ORDER BY cab.name) AS cable_names,
    (SELECT COUNT(*) FROM osp.splice_tray st WHERE st.closure_id = sc.id) AS tray_count,
    (SELECT COUNT(*)
     FROM osp.splice_connection spc
     JOIN osp.splice_tray st2 ON spc.tray_id = st2.id
     WHERE st2.closure_id = sc.id AND spc.status = 'ACTIVE') AS active_splice_count
FROM osp.splice_closure sc
    JOIN osp.closure_type ct ON sc.closure_type = ct.code
    LEFT JOIN osp.pit p ON sc.pit_id = p.id
    LEFT JOIN osp.closure_cable_entry cce ON sc.id = cce.closure_id
    LEFT JOIN osp.cable cab ON cce.cable_id = cab.id
GROUP BY sc.id, sc.name, sc.closure_type, ct.max_splices, p.name, sc.status;


-- =============================================================================
-- SECTION 12: FUNCTIONS FOR FIBER TRACING
-- =============================================================================

-- Recursive fiber trace: given a starting fiber, walk through all splice
-- connections to build the end-to-end path.
--
-- Returns ordered set of (cable_name, fiber_number, closure_name, splice_loss)
-- representing every fiber segment and splice point along the path.
--
-- Uses PL/pgSQL with a visited-fibers array to prevent cycles. A fiber
-- can appear in at most one splice_connection as a_fiber or b_fiber,
-- so we walk the chain: start_fiber -> splice -> next_fiber -> splice -> ...
--
-- Usage: SELECT * FROM osp.trace_fiber('fiber-uuid-here');
--
CREATE OR REPLACE FUNCTION osp.trace_fiber(start_fiber_id UUID)
RETURNS TABLE (
    hop             INTEGER,
    cable_id        UUID,
    cable_name      TEXT,
    fiber_id        UUID,
    fiber_number    INTEGER,
    tube_number     INTEGER,
    fiber_color     TEXT,
    closure_id      UUID,
    closure_name    TEXT,
    splice_loss_db  NUMERIC,
    cumulative_loss_db NUMERIC
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_current_fiber_id UUID;
    v_next_fiber_id    UUID;
    v_hop              INTEGER := 0;
    v_cum_loss         NUMERIC := 0;
    v_visited          UUID[] := ARRAY[]::UUID[];
    v_rec              RECORD;
    v_splice           RECORD;
BEGIN
    -- Emit the starting fiber (hop 1)
    SELECT f.id, f.cable_id, c.name, f.fiber_number, t.tube_number, f.color
    INTO v_rec
    FROM osp.fiber f
        JOIN osp.cable c ON f.cable_id = c.id
        JOIN osp.tube t ON f.tube_id = t.id
    WHERE f.id = start_fiber_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    v_hop := 1;
    hop := v_hop;
    cable_id := v_rec.cable_id;
    cable_name := v_rec.name;
    fiber_id := v_rec.id;
    fiber_number := v_rec.fiber_number;
    tube_number := v_rec.tube_number;
    fiber_color := v_rec.color;
    closure_id := NULL;
    closure_name := NULL;
    splice_loss_db := 0;
    cumulative_loss_db := 0;
    RETURN NEXT;

    v_visited := v_visited || start_fiber_id;
    v_current_fiber_id := start_fiber_id;

    -- Walk through splices
    LOOP
        -- Find a splice connection involving the current fiber
        SELECT
            spc.id AS splice_id,
            CASE WHEN spc.a_fiber_id = v_current_fiber_id
                 THEN spc.b_fiber_id ELSE spc.a_fiber_id END AS other_fiber_id,
            COALESCE(spc.loss_db, 0) AS loss,
            sc.id AS sc_id,
            sc.name AS sc_name
        INTO v_splice
        FROM osp.splice_connection spc
            JOIN osp.splice_tray st ON spc.tray_id = st.id
            JOIN osp.splice_closure sc ON st.closure_id = sc.id
        WHERE (spc.a_fiber_id = v_current_fiber_id OR spc.b_fiber_id = v_current_fiber_id)
          AND spc.status = 'ACTIVE'
          AND CASE WHEN spc.a_fiber_id = v_current_fiber_id
                   THEN spc.b_fiber_id ELSE spc.a_fiber_id END != ALL(v_visited);

        EXIT WHEN NOT FOUND;

        v_next_fiber_id := v_splice.other_fiber_id;
        v_cum_loss := v_cum_loss + v_splice.loss;
        v_visited := v_visited || v_next_fiber_id;
        v_hop := v_hop + 1;

        -- Look up the next fiber details
        SELECT f.id, f.cable_id, c.name, f.fiber_number, t.tube_number, f.color
        INTO v_rec
        FROM osp.fiber f
            JOIN osp.cable c ON f.cable_id = c.id
            JOIN osp.tube t ON f.tube_id = t.id
        WHERE f.id = v_next_fiber_id;

        hop := v_hop;
        cable_id := v_rec.cable_id;
        cable_name := v_rec.name;
        fiber_id := v_rec.id;
        fiber_number := v_rec.fiber_number;
        tube_number := v_rec.tube_number;
        fiber_color := v_rec.color;
        closure_id := v_splice.sc_id;
        closure_name := v_splice.sc_name;
        splice_loss_db := v_splice.loss;
        cumulative_loss_db := v_cum_loss;
        RETURN NEXT;

        v_current_fiber_id := v_next_fiber_id;

        -- Safety limit
        EXIT WHEN v_hop >= 200;
    END LOOP;

    RETURN;
END;
$$;


-- Trace all fibers in a cable end-to-end (batch version)
-- Useful for: "show me where all 48 fibers in cable X go"
CREATE OR REPLACE FUNCTION osp.trace_cable_fibers(p_cable_id UUID)
RETURNS TABLE (
    fiber_number    INTEGER,
    fiber_color     TEXT,
    path_hops       INTEGER,
    end_cable_name  TEXT,
    end_fiber_number INTEGER,
    total_loss_db   NUMERIC,
    total_splices   INTEGER
)
LANGUAGE sql STABLE
AS $$
    SELECT
        f.fiber_number,
        f.color AS fiber_color,
        (SELECT MAX(hop) FROM osp.trace_fiber(f.id)) AS path_hops,
        (SELECT cable_name FROM osp.trace_fiber(f.id) ORDER BY hop DESC LIMIT 1) AS end_cable_name,
        (SELECT fiber_number FROM osp.trace_fiber(f.id) ORDER BY hop DESC LIMIT 1) AS end_fiber_number,
        (SELECT cumulative_loss_db FROM osp.trace_fiber(f.id) ORDER BY hop DESC LIMIT 1) AS total_loss_db,
        (SELECT COUNT(*) FROM osp.trace_fiber(f.id) WHERE closure_id IS NOT NULL)::INTEGER AS total_splices
    FROM osp.fiber f
    WHERE f.cable_id = p_cable_id
    ORDER BY f.fiber_number;
$$;


-- =============================================================================
-- SECTION 13: HELPER FUNCTIONS
-- =============================================================================

-- Auto-generate fiber records when a cable is created
-- Call this after inserting a cable to populate tubes and fibers
-- Uses standard TIA-598-D color sequence
CREATE OR REPLACE FUNCTION osp.generate_cable_fibers(p_cable_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cable         RECORD;
    v_tube_count    INTEGER;
    v_fibers_per    INTEGER;
    v_tube_id       UUID;
    v_fiber_num     INTEGER := 0;
    v_colors        TEXT[] := ARRAY[
        'Blue', 'Orange', 'Green', 'Brown', 'Slate',
        'White', 'Red', 'Black', 'Yellow', 'Violet',
        'Rose', 'Aqua'
    ];
BEGIN
    SELECT * INTO v_cable FROM osp.cable WHERE id = p_cable_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cable % not found', p_cable_id;
    END IF;

    v_tube_count := COALESCE(v_cable.tube_count, CEIL(v_cable.fiber_count::NUMERIC / 12));
    v_fibers_per := COALESCE(v_cable.fibers_per_tube, 12);

    -- Update cable with computed values if not set
    UPDATE osp.cable SET
        tube_count = v_tube_count,
        fibers_per_tube = v_fibers_per
    WHERE id = p_cable_id;

    FOR tube_num IN 1..v_tube_count LOOP
        v_tube_id := gen_random_uuid();

        INSERT INTO osp.tube (id, cable_id, tube_number, color, fiber_count, tube_type)
        VALUES (
            v_tube_id,
            p_cable_id,
            tube_num,
            v_colors[((tube_num - 1) % 12) + 1],
            LEAST(v_fibers_per, v_cable.fiber_count - v_fiber_num),
            CASE WHEN v_cable.cable_type = 'RIBBON' THEN 'RIBBON' ELSE 'BUFFER' END
        );

        FOR fiber_in_tube IN 1..v_fibers_per LOOP
            v_fiber_num := v_fiber_num + 1;
            EXIT WHEN v_fiber_num > v_cable.fiber_count;

            INSERT INTO osp.fiber (cable_id, tube_id, fiber_number, fiber_in_tube, color, fiber_mode)
            VALUES (
                p_cable_id,
                v_tube_id,
                v_fiber_num,
                fiber_in_tube,
                v_colors[((fiber_in_tube - 1) % 12) + 1],
                v_cable.fiber_mode
            );
        END LOOP;

        EXIT WHEN v_fiber_num >= v_cable.fiber_count;
    END LOOP;

    RETURN v_fiber_num;
END;
$$;


-- Calculate route length from geometry (in metres, using MGA Zone 55 for VIC/TAS)
-- Adjust the target SRID based on deployment region
CREATE OR REPLACE FUNCTION osp.calc_route_length_m(route_geom GEOMETRY)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE
AS $$
    SELECT ROUND(ST_Length(ST_Transform(route_geom, 7855))::NUMERIC, 2);
$$;


-- =============================================================================
-- SECTION 14: TRIGGERS
-- =============================================================================

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION osp.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

-- Apply updated_at triggers to all mutable tables
DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOR tbl IN
        SELECT unnest(ARRAY[
            'route', 'pit', 'pole', 'duct_segment', 'subduct',
            'cable', 'splice_closure', 'splice_connection',
            'fiber_assignment', 'equipment'
        ])
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%s_updated_at
             BEFORE UPDATE ON osp.%I
             FOR EACH ROW EXECUTE FUNCTION osp.set_updated_at()',
            tbl, tbl
        );
    END LOOP;
END;
$$;


-- =============================================================================
-- SECTION 15: SAMPLE QUERY RECIPES
-- =============================================================================

-- These are provided as comments for reference. Copy and adapt as needed.

/*
-- Q1: Show all fibers in cable 'C-SYD-DIST-0042'
SELECT * FROM osp.v_cable_fibers
WHERE cable_name = 'C-SYD-DIST-0042'
ORDER BY fiber_number;

-- Q2: Trace fiber 12 end-to-end
SELECT * FROM osp.trace_fiber(
    (SELECT id FROM osp.fiber f
     JOIN osp.cable c ON f.cable_id = c.id
     WHERE c.name = 'C-SYD-DIST-0042' AND f.fiber_number = 12)
);

-- Q3: What cables are in duct segment between PIT-001 and PIT-002?
SELECT c.name, c.cable_type, c.fiber_count, c.status
FROM osp.cable_in_duct cid
    JOIN osp.cable c ON cid.cable_id = c.id
    JOIN osp.duct_segment ds ON cid.duct_segment_id = ds.id
    JOIN osp.pit fp ON ds.from_pit_id = fp.id
    JOIN osp.pit tp ON ds.to_pit_id = tp.id
WHERE fp.name = 'PIT-001' AND tp.name = 'PIT-002';

-- Q4: Duct occupancy report for a route
SELECT * FROM osp.v_duct_occupancy
WHERE duct_segment_id IN (
    SELECT id FROM osp.duct_segment WHERE route_id = 'some-route-uuid'
)
ORDER BY from_pit_name;

-- Q5: Find all unassigned (spare) fibers in a cable
SELECT f.fiber_number, f.color, t.tube_number, t.color AS tube_color
FROM osp.fiber f
    JOIN osp.tube t ON f.tube_id = t.id
WHERE f.cable_id = 'some-cable-uuid'
  AND f.status = 'ACTIVE'
  AND f.id NOT IN (
      SELECT fiber_id FROM osp.fiber_assignment WHERE released_date IS NULL
  )
ORDER BY f.fiber_number;

-- Q6: Splice closure utilisation report
SELECT
    closure_name,
    closure_type,
    closure_capacity,
    active_splice_count,
    ROUND(active_splice_count * 100.0 / NULLIF(closure_capacity, 0), 1) AS utilisation_pct,
    cable_count,
    cable_names
FROM osp.v_closure_summary
WHERE status = 'ACTIVE'
ORDER BY utilisation_pct DESC;

-- Q7: Find all pits within 500m of a location (e.g., customer address)
SELECT p.name, p.pit_type, p.status,
       ST_Distance(
           ST_Transform(p.geom, 7855),
           ST_Transform(ST_SetSRID(ST_MakePoint(151.2093, -33.8688), 7844), 7855)
       ) AS distance_m
FROM osp.pit p
WHERE ST_DWithin(
    p.geom::geography,
    ST_SetSRID(ST_MakePoint(151.2093, -33.8688), 7844)::geography,
    500
)
ORDER BY distance_m;

-- Q8: Route length summary
SELECT r.name, r.route_type, r.status,
       osp.calc_route_length_m(r.geom) AS length_m,
       COUNT(DISTINCT ds.id) AS duct_segments,
       COUNT(DISTINCT c.id) AS cables
FROM osp.route r
    LEFT JOIN osp.duct_segment ds ON r.id = ds.route_id
    LEFT JOIN osp.cable c ON r.id = c.route_id
GROUP BY r.id, r.name, r.route_type, r.status
ORDER BY length_m DESC;

-- Q9: Fiber path between two G-NAF addresses
-- (Assumes fiber_assignment has customer_ref or service_ref linking to address)
-- This would be an application-level query combining G-NAF lookup with trace_fiber()

-- Q10: Leased duct inventory
SELECT ds.name, ds.owner_name, ds.lease_ref, ds.lease_expiry,
       fp.name AS from_pit, tp.name AS to_pit,
       ds.length_m, ds.status,
       COUNT(cid.id) AS our_cables_in_duct
FROM osp.duct_segment ds
    JOIN osp.pit fp ON ds.from_pit_id = fp.id
    JOIN osp.pit tp ON ds.to_pit_id = tp.id
    LEFT JOIN osp.cable_in_duct cid ON ds.id = cid.duct_segment_id
WHERE ds.ownership IN ('LEASED', 'IRU')
GROUP BY ds.id, ds.name, ds.owner_name, ds.lease_ref, ds.lease_expiry,
         fp.name, tp.name, ds.length_m, ds.status
ORDER BY ds.lease_expiry;
*/


-- =============================================================================
-- DONE
-- =============================================================================
-- Schema version: 1.0.0
-- Designed for: FiberCo Australia - OSP Network Asset Management
-- Database: PostgreSQL 16 + PostGIS 3.5
-- CRS: GDA2020 (EPSG:7844)
-- =============================================================================
