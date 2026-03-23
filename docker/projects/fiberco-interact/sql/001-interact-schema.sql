-- =============================================================================
-- FiberCo Interact Platform - Database Schema
-- Schema: interact
-- Database: fiberco-interact
-- Generated: 2026-03-17
-- =============================================================================

BEGIN;

-- Create schema
CREATE SCHEMA IF NOT EXISTS interact;

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Generic updated_at trigger function (applies to ALL tables with updated_at)
CREATE OR REPLACE FUNCTION interact.set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- LRN auto-generator for locations and dwellings
CREATE OR REPLACE FUNCTION interact.generate_lrn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.lrn IS NULL OR NEW.lrn = '' THEN
        NEW.lrn := 'LRN' || LPAD(FLOOR(RANDOM() * 999999999)::TEXT, 9, '0');
        WHILE EXISTS (SELECT 1 FROM interact.locations WHERE lrn = NEW.lrn)
           OR EXISTS (SELECT 1 FROM interact.dwellings WHERE lrn = NEW.lrn) LOOP
            NEW.lrn := 'LRN' || LPAD(FLOOR(RANDOM() * 999999999)::TEXT, 9, '0');
        END LOOP;
    END IF;
    -- Auto-set geom from lat/lng (only for tables that have these columns)
    IF TG_TABLE_NAME = 'locations' THEN
        IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
            NEW.geom := ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 7844);
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Location geom updater (for UPDATE on locations)
CREATE OR REPLACE FUNCTION interact.update_location_geom() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.latitude IS NOT NULL AND NEW.longitude IS NOT NULL THEN
        NEW.geom := ST_SetSRID(ST_MakePoint(NEW.longitude, NEW.latitude), 7844);
    END IF;
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Service ID auto-generator (SVC-XXXXXX hex)
CREATE OR REPLACE FUNCTION interact.generate_service_id() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.service_id IS NULL OR NEW.service_id = '' THEN
        NEW.service_id := 'SVC-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        WHILE EXISTS (SELECT 1 FROM interact.services WHERE service_id = NEW.service_id) LOOP
            NEW.service_id := 'SVC-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Order number auto-generator (ORD-XXXXXX hex)
CREATE OR REPLACE FUNCTION interact.generate_order_number() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.order_number IS NULL OR NEW.order_number = '' THEN
        NEW.order_number := 'ORD-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        WHILE EXISTS (SELECT 1 FROM interact.service_orders WHERE order_number = NEW.order_number) LOOP
            NEW.order_number := 'ORD-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Ticket number auto-generator (TKT-XXXXXX hex)
CREATE OR REPLACE FUNCTION interact.generate_ticket_number() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.ticket_number IS NULL OR NEW.ticket_number = '' THEN
        NEW.ticket_number := 'TKT-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        WHILE EXISTS (SELECT 1 FROM interact.trouble_tickets WHERE ticket_number = NEW.ticket_number) LOOP
            NEW.ticket_number := 'TKT-' || UPPER(ENCODE(gen_random_bytes(3), 'hex'));
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- 1. AUTH & RBAC TABLES
-- =============================================================================

CREATE TABLE interact.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'viewer' CHECK (role IN ('super_admin','admin','manager','operator','viewer')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','locked','suspended')),
    failed_login_attempts INT DEFAULT 0,
    last_login TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE interact.sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES interact.users(id),
    token_hash TEXT NOT NULL,
    ip_address TEXT,
    user_agent TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    last_activity TIMESTAMPTZ DEFAULT NOW(),
    is_valid BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE interact.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES interact.users(id),
    action TEXT NOT NULL,
    category TEXT NOT NULL,
    resource_type TEXT,
    resource_id TEXT,
    details JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 2. LOCATION REGISTRY
-- =============================================================================

CREATE TABLE interact.locations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lrn TEXT UNIQUE NOT NULL,
    gnaf_pid TEXT,
    location_type TEXT NOT NULL DEFAULT 'premises' CHECK (location_type IN ('premises','mdu','exchange','node','pop','cabinet','pit')),
    name TEXT,
    street_address TEXT NOT NULL,
    locality TEXT NOT NULL,
    state TEXT NOT NULL,
    postcode TEXT,
    latitude NUMERIC,
    longitude NUMERIC,
    geom GEOMETRY(Point, 7844),
    service_class INT DEFAULT 0,
    network_status TEXT DEFAULT 'planned' CHECK (network_status IN ('planned','designed','building','active','decommissioned')),
    infrastructure_type TEXT DEFAULT 'GPON' CHECK (infrastructure_type IN ('GPON','XGS-PON','P2P','DWDM','ETHERNET')),
    total_dwellings INT DEFAULT 0,
    notes TEXT,
    created_by UUID REFERENCES interact.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_location_lrn
    BEFORE INSERT ON interact.locations
    FOR EACH ROW EXECUTE FUNCTION interact.generate_lrn();

CREATE TRIGGER trg_location_geom
    BEFORE UPDATE ON interact.locations
    FOR EACH ROW EXECUTE FUNCTION interact.update_location_geom();

-- =============================================================================
-- 3. DWELLINGS
-- =============================================================================

CREATE TABLE interact.dwellings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lrn TEXT UNIQUE NOT NULL,
    location_id UUID NOT NULL REFERENCES interact.locations(id) ON DELETE CASCADE,
    gnaf_pid TEXT,
    unit_type TEXT,
    unit_number TEXT,
    level_type TEXT,
    level_number TEXT,
    full_address TEXT NOT NULL,
    service_status TEXT DEFAULT 'not_ready' CHECK (service_status IN ('not_ready','ready','in_service','suspended','ceased')),
    service_class INT DEFAULT 0,
    notes TEXT,
    created_by UUID REFERENCES interact.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_dwelling_lrn
    BEFORE INSERT ON interact.dwellings
    FOR EACH ROW EXECUTE FUNCTION interact.generate_lrn();

CREATE TRIGGER trg_dwelling_updated
    BEFORE UPDATE ON interact.dwellings
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

-- =============================================================================
-- 4. SERVICE POINTS
-- =============================================================================

CREATE TABLE interact.service_points (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    location_id UUID NOT NULL REFERENCES interact.locations(id),
    dwelling_id UUID REFERENCES interact.dwellings(id),
    point_type TEXT NOT NULL CHECK (point_type IN ('NTD','FDP','PATCH_PANEL','DEMARCATION','ODF')),
    equipment_ref TEXT,
    port_count INT DEFAULT 4,
    ports_used INT DEFAULT 0,
    status TEXT DEFAULT 'planned' CHECK (status IN ('planned','installed','active','faulty','decommissioned')),
    installed_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 5. PRODUCT CATALOG
-- =============================================================================

CREATE TABLE interact.bandwidth_tiers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    download_mbps INT NOT NULL,
    upload_mbps INT NOT NULL,
    sort_order INT DEFAULT 0
);

CREATE TABLE interact.sla_tiers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    availability_pct NUMERIC(5,2),
    fault_response_hours NUMERIC(4,1),
    restore_target_hours NUMERIC(4,1),
    price_multiplier NUMERIC(3,2) DEFAULT 1.00,
    sort_order INT DEFAULT 0
);

CREATE TABLE interact.products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    code TEXT UNIQUE NOT NULL,
    product_type TEXT NOT NULL CHECK (product_type IN ('ethernet','wavelength','dark_fibre','broadband','backhaul','colocation')),
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    requires_ntu BOOLEAN DEFAULT true,
    min_term_months INT DEFAULT 12,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE interact.product_pricing (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL REFERENCES interact.products(id),
    bandwidth_tier_id UUID REFERENCES interact.bandwidth_tiers(id),
    sla_tier_id UUID REFERENCES interact.sla_tiers(id),
    monthly_recurring NUMERIC(10,2) NOT NULL,
    non_recurring NUMERIC(10,2) DEFAULT 0,
    per_km_monthly NUMERIC(10,2) DEFAULT 0,
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to DATE,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 6. CUSTOMERS
-- =============================================================================

CREATE TABLE interact.customers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    customer_type TEXT NOT NULL CHECK (customer_type IN ('wholesale_rsp','enterprise','carrier','government')),
    abn TEXT,
    acn TEXT,
    billing_email TEXT,
    status TEXT DEFAULT 'active' CHECK (status IN ('active','suspended','terminated')),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE interact.customer_contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id UUID NOT NULL REFERENCES interact.customers(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    role TEXT CHECK (role IN ('technical','billing','ordering','escalation','primary')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================================
-- 7. SERVICES
-- =============================================================================

CREATE TABLE interact.services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id TEXT UNIQUE NOT NULL,
    customer_id UUID NOT NULL REFERENCES interact.customers(id),
    product_id UUID NOT NULL REFERENCES interact.products(id),
    bandwidth_tier_id UUID REFERENCES interact.bandwidth_tiers(id),
    sla_tier_id UUID REFERENCES interact.sla_tiers(id),
    a_end_location_id UUID REFERENCES interact.locations(id),
    z_end_location_id UUID REFERENCES interact.locations(id),
    a_end_dwelling_id UUID REFERENCES interact.dwellings(id),
    status TEXT DEFAULT 'ordered' CHECK (status IN ('ordered','designing','building','testing','active','suspended','ceased')),
    circuit_ref TEXT,
    monthly_charge NUMERIC(10,2),
    contract_start DATE,
    contract_end DATE,
    activated_at TIMESTAMPTZ,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_service_id
    BEFORE INSERT ON interact.services
    FOR EACH ROW EXECUTE FUNCTION interact.generate_service_id();

-- =============================================================================
-- 8. SERVICE ORDERS
-- =============================================================================

CREATE TABLE interact.service_orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_number TEXT UNIQUE NOT NULL,
    order_type TEXT NOT NULL CHECK (order_type IN ('new','modify','cease','relocate')),
    customer_id UUID NOT NULL REFERENCES interact.customers(id),
    service_id UUID REFERENCES interact.services(id),
    product_id UUID REFERENCES interact.products(id),
    a_end_location_id UUID REFERENCES interact.locations(id),
    z_end_location_id UUID REFERENCES interact.locations(id),
    bandwidth_tier_id UUID REFERENCES interact.bandwidth_tiers(id),
    sla_tier_id UUID REFERENCES interact.sla_tiers(id),
    status TEXT DEFAULT 'received' CHECK (status IN ('received','qualified','accepted','designing','building','testing','complete','rejected','cancelled')),
    requested_date DATE,
    committed_date DATE,
    completed_date DATE,
    rejection_reason TEXT,
    notes TEXT,
    created_by UUID REFERENCES interact.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_order_number
    BEFORE INSERT ON interact.service_orders
    FOR EACH ROW EXECUTE FUNCTION interact.generate_order_number();

-- =============================================================================
-- 9. TROUBLE TICKETS
-- =============================================================================

CREATE TABLE interact.trouble_tickets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ticket_number TEXT UNIQUE NOT NULL,
    service_id UUID REFERENCES interact.services(id),
    customer_id UUID REFERENCES interact.customers(id),
    priority TEXT NOT NULL CHECK (priority IN ('P1','P2','P3','P4')),
    status TEXT DEFAULT 'open' CHECK (status IN ('open','acknowledged','in_progress','pending_customer','resolved','closed')),
    category TEXT,
    summary TEXT NOT NULL,
    description TEXT,
    root_cause TEXT,
    resolution TEXT,
    sla_response_target TIMESTAMPTZ,
    sla_restore_target TIMESTAMPTZ,
    sla_response_met BOOLEAN,
    sla_restore_met BOOLEAN,
    assigned_to UUID REFERENCES interact.users(id),
    reported_by UUID REFERENCES interact.users(id),
    resolved_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TRIGGER trg_ticket_number
    BEFORE INSERT ON interact.trouble_tickets
    FOR EACH ROW EXECUTE FUNCTION interact.generate_ticket_number();

-- =============================================================================
-- UPDATED_AT TRIGGERS (applied to ALL tables with updated_at)
-- =============================================================================

CREATE TRIGGER trg_users_updated
    BEFORE UPDATE ON interact.users
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_service_points_updated
    BEFORE UPDATE ON interact.service_points
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_products_updated
    BEFORE UPDATE ON interact.products
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_customers_updated
    BEFORE UPDATE ON interact.customers
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_services_updated
    BEFORE UPDATE ON interact.services
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_service_orders_updated
    BEFORE UPDATE ON interact.service_orders
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

CREATE TRIGGER trg_trouble_tickets_updated
    BEFORE UPDATE ON interact.trouble_tickets
    FOR EACH ROW EXECUTE FUNCTION interact.set_updated_at();

-- =============================================================================
-- 10. INDEXES
-- =============================================================================

-- Auth & RBAC
CREATE INDEX idx_users_email ON interact.users USING btree (email);
CREATE INDEX idx_users_role ON interact.users USING btree (role);
CREATE INDEX idx_users_status ON interact.users USING btree (status);
CREATE INDEX idx_sessions_user_id ON interact.sessions USING btree (user_id);
CREATE INDEX idx_sessions_expires_at ON interact.sessions USING btree (expires_at);
CREATE INDEX idx_sessions_is_valid ON interact.sessions USING btree (is_valid);
CREATE INDEX idx_audit_log_user_id ON interact.audit_log USING btree (user_id);
CREATE INDEX idx_audit_log_action ON interact.audit_log USING btree (action);
CREATE INDEX idx_audit_log_category ON interact.audit_log USING btree (category);
CREATE INDEX idx_audit_log_resource ON interact.audit_log USING btree (resource_type, resource_id);
CREATE INDEX idx_audit_log_created_at ON interact.audit_log USING btree (created_at);

-- Locations
CREATE INDEX idx_locations_lrn ON interact.locations USING btree (lrn);
CREATE INDEX idx_locations_gnaf_pid ON interact.locations USING btree (gnaf_pid);
CREATE INDEX idx_locations_location_type ON interact.locations USING btree (location_type);
CREATE INDEX idx_locations_service_class ON interact.locations USING btree (service_class);
CREATE INDEX idx_locations_network_status ON interact.locations USING btree (network_status);
CREATE INDEX idx_locations_infrastructure ON interact.locations USING btree (infrastructure_type);
CREATE INDEX idx_locations_locality ON interact.locations USING btree (locality);
CREATE INDEX idx_locations_state ON interact.locations USING btree (state);
CREATE INDEX idx_locations_postcode ON interact.locations USING btree (postcode);
CREATE INDEX idx_locations_created_by ON interact.locations USING btree (created_by);
CREATE INDEX idx_locations_geom ON interact.locations USING gist (geom);
CREATE INDEX idx_locations_address_trgm ON interact.locations USING gin (street_address gin_trgm_ops);
CREATE INDEX idx_locations_locality_trgm ON interact.locations USING gin (locality gin_trgm_ops);

-- Dwellings
CREATE INDEX idx_dwellings_lrn ON interact.dwellings USING btree (lrn);
CREATE INDEX idx_dwellings_location_id ON interact.dwellings USING btree (location_id);
CREATE INDEX idx_dwellings_gnaf_pid ON interact.dwellings USING btree (gnaf_pid);
CREATE INDEX idx_dwellings_service_status ON interact.dwellings USING btree (service_status);
CREATE INDEX idx_dwellings_service_class ON interact.dwellings USING btree (service_class);
CREATE INDEX idx_dwellings_created_by ON interact.dwellings USING btree (created_by);
CREATE INDEX idx_dwellings_address_trgm ON interact.dwellings USING gin (full_address gin_trgm_ops);

-- Service Points
CREATE INDEX idx_service_points_location_id ON interact.service_points USING btree (location_id);
CREATE INDEX idx_service_points_dwelling_id ON interact.service_points USING btree (dwelling_id);
CREATE INDEX idx_service_points_point_type ON interact.service_points USING btree (point_type);
CREATE INDEX idx_service_points_status ON interact.service_points USING btree (status);

-- Product Catalog
CREATE INDEX idx_products_product_type ON interact.products USING btree (product_type);
CREATE INDEX idx_products_is_active ON interact.products USING btree (is_active);
CREATE INDEX idx_product_pricing_product_id ON interact.product_pricing USING btree (product_id);
CREATE INDEX idx_product_pricing_bandwidth ON interact.product_pricing USING btree (bandwidth_tier_id);
CREATE INDEX idx_product_pricing_sla ON interact.product_pricing USING btree (sla_tier_id);
CREATE INDEX idx_product_pricing_active ON interact.product_pricing USING btree (is_active);
CREATE INDEX idx_product_pricing_effective ON interact.product_pricing USING btree (effective_from, effective_to);

-- Customers
CREATE INDEX idx_customers_customer_type ON interact.customers USING btree (customer_type);
CREATE INDEX idx_customers_status ON interact.customers USING btree (status);
CREATE INDEX idx_customers_abn ON interact.customers USING btree (abn);
CREATE INDEX idx_customer_contacts_customer_id ON interact.customer_contacts USING btree (customer_id);
CREATE INDEX idx_customer_contacts_role ON interact.customer_contacts USING btree (role);

-- Services
CREATE INDEX idx_services_service_id ON interact.services USING btree (service_id);
CREATE INDEX idx_services_customer_id ON interact.services USING btree (customer_id);
CREATE INDEX idx_services_product_id ON interact.services USING btree (product_id);
CREATE INDEX idx_services_bandwidth_tier ON interact.services USING btree (bandwidth_tier_id);
CREATE INDEX idx_services_sla_tier ON interact.services USING btree (sla_tier_id);
CREATE INDEX idx_services_a_end ON interact.services USING btree (a_end_location_id);
CREATE INDEX idx_services_z_end ON interact.services USING btree (z_end_location_id);
CREATE INDEX idx_services_a_end_dwelling ON interact.services USING btree (a_end_dwelling_id);
CREATE INDEX idx_services_status ON interact.services USING btree (status);

-- Service Orders
CREATE INDEX idx_service_orders_order_number ON interact.service_orders USING btree (order_number);
CREATE INDEX idx_service_orders_order_type ON interact.service_orders USING btree (order_type);
CREATE INDEX idx_service_orders_customer_id ON interact.service_orders USING btree (customer_id);
CREATE INDEX idx_service_orders_service_id ON interact.service_orders USING btree (service_id);
CREATE INDEX idx_service_orders_product_id ON interact.service_orders USING btree (product_id);
CREATE INDEX idx_service_orders_a_end ON interact.service_orders USING btree (a_end_location_id);
CREATE INDEX idx_service_orders_z_end ON interact.service_orders USING btree (z_end_location_id);
CREATE INDEX idx_service_orders_bandwidth ON interact.service_orders USING btree (bandwidth_tier_id);
CREATE INDEX idx_service_orders_sla ON interact.service_orders USING btree (sla_tier_id);
CREATE INDEX idx_service_orders_status ON interact.service_orders USING btree (status);
CREATE INDEX idx_service_orders_created_by ON interact.service_orders USING btree (created_by);

-- Trouble Tickets
CREATE INDEX idx_tickets_ticket_number ON interact.trouble_tickets USING btree (ticket_number);
CREATE INDEX idx_tickets_service_id ON interact.trouble_tickets USING btree (service_id);
CREATE INDEX idx_tickets_customer_id ON interact.trouble_tickets USING btree (customer_id);
CREATE INDEX idx_tickets_priority ON interact.trouble_tickets USING btree (priority);
CREATE INDEX idx_tickets_status ON interact.trouble_tickets USING btree (status);
CREATE INDEX idx_tickets_category ON interact.trouble_tickets USING btree (category);
CREATE INDEX idx_tickets_assigned_to ON interact.trouble_tickets USING btree (assigned_to);
CREATE INDEX idx_tickets_reported_by ON interact.trouble_tickets USING btree (reported_by);
CREATE INDEX idx_tickets_created_at ON interact.trouble_tickets USING btree (created_at);

-- =============================================================================
-- 11. SEED DATA
-- =============================================================================

-- Super admin user (password: Ev0lv3@1993!!)
INSERT INTO interact.users (email, password_hash, full_name, role, status) VALUES (
    'jberry@fiberco.com.au',
    crypt('Ev0lv3@1993!!', gen_salt('bf', 12)),
    'System Administrator',
    'super_admin',
    'active'
);

-- Bandwidth tiers (all symmetric)
INSERT INTO interact.bandwidth_tiers (name, code, download_mbps, upload_mbps, sort_order) VALUES
    ('10M Symmetric',   'TIER_10M',   10,    10,    10),
    ('20M Symmetric',   'TIER_20M',   20,    20,    20),
    ('50M Symmetric',   'TIER_50M',   50,    50,    30),
    ('100M Symmetric',  'TIER_100M',  100,   100,   40),
    ('200M Symmetric',  'TIER_200M',  200,   200,   50),
    ('500M Symmetric',  'TIER_500M',  500,   500,   60),
    ('1G Symmetric',    'TIER_1G',    1000,  1000,  70),
    ('10G Symmetric',   'TIER_10G',   10000, 10000, 80);

-- SLA tiers
INSERT INTO interact.sla_tiers (name, code, availability_pct, fault_response_hours, restore_target_hours, price_multiplier, sort_order) VALUES
    ('Standard', 'STANDARD', 99.50,  4.0,  24.0, 1.00, 10),
    ('Enhanced', 'ENHANCED', 99.90,  2.0,   8.0, 1.30, 20),
    ('Premium',  'PREMIUM',  99.95,  1.0,   4.0, 1.80, 30),
    ('Critical', 'CRITICAL', 99.99,  0.25,  2.0, 2.50, 40);

-- Products
INSERT INTO interact.products (name, code, product_type, description, requires_ntu, min_term_months) VALUES
    ('Enterprise Ethernet', 'ENT_ETH',     'ethernet',    'Point-to-point Ethernet service with guaranteed bandwidth', true,  12),
    ('Wavelength Service',  'WAVELENGTH',  'wavelength',  'Dedicated wavelength on FiberCo DWDM network',             false, 36),
    ('Dark Fibre',          'DARK_FIBRE',  'dark_fibre',  'Unlit fibre pair lease between two endpoints',              false, 60),
    ('Broadband',           'BROADBAND',   'broadband',   'GPON-based broadband service for residential/SMB',          true,  12),
    ('Backhaul',            'BACKHAUL',    'backhaul',    'High-capacity backhaul between POPs and exchanges',          false, 36),
    ('Co-location',         'COLOCATION',  'colocation',  'Rack space and power in FiberCo facilities',                false, 12);

-- Enterprise Ethernet pricing across all bandwidth + SLA combinations
-- Base MRC per bandwidth tier, multiplied by SLA price_multiplier
-- NRC is a flat install fee that varies by bandwidth tier
INSERT INTO interact.product_pricing (product_id, bandwidth_tier_id, sla_tier_id, monthly_recurring, non_recurring, effective_from, is_active)
SELECT
    p.id,
    bt.id,
    st.id,
    ROUND(base.base_mrc * st.price_multiplier, 2),
    base.base_nrc,
    '2026-01-01'::DATE,
    true
FROM interact.products p
CROSS JOIN interact.bandwidth_tiers bt
CROSS JOIN interact.sla_tiers st
JOIN (VALUES
    ('TIER_10M',   250.00,  500.00),
    ('TIER_20M',   400.00,  500.00),
    ('TIER_50M',   650.00,  750.00),
    ('TIER_100M',  900.00,  750.00),
    ('TIER_200M', 1400.00, 1000.00),
    ('TIER_500M', 2200.00, 1000.00),
    ('TIER_1G',   3500.00, 1500.00),
    ('TIER_10G',  8500.00, 2500.00)
) AS base(tier_code, base_mrc, base_nrc) ON base.tier_code = bt.code
WHERE p.code = 'ENT_ETH';

COMMIT;
