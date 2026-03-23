#!/bin/bash
# G-NAF Import Script for FiberCo
# Downloads, extracts, and imports the G-NAF dataset into PostgreSQL/PostGIS
set -euo pipefail

DB_HOST="${DB_HOST:-fiberco-naf-db}"
DB_USER="${DB_USER:-app}"
DB_NAME="${DB_NAME:-fiberco-naf}"
DB_PASS="${DB_PASS:-app}"
GNAF_ZIP="${1:-/data/gnaf_feb26.zip}"
WORK_DIR="/tmp/gnaf_import"

export PGPASSWORD="$DB_PASS"
PSQL="psql -h $DB_HOST -U $DB_USER -d $DB_NAME -q"

echo "=== G-NAF Import for FiberCo ==="
echo "Database: $DB_NAME @ $DB_HOST"

# 1. Extract
echo "[1/7] Extracting G-NAF archive..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
unzip -q "$GNAF_ZIP" -d "$WORK_DIR"

# Find the extracted directory structure
GNAF_DIR=$(find "$WORK_DIR" -maxdepth 2 -name "Authority Code" -type d | head -1 | xargs dirname)
if [ -z "$GNAF_DIR" ]; then
  echo "ERROR: Could not find G-NAF data directory"
  exit 1
fi
echo "  Found data at: $GNAF_DIR"

EXTRAS_DIR=$(find "$WORK_DIR" -maxdepth 3 -name "GNAF_TableCreation_Scripts" -type d | head -1 | xargs dirname)
echo "  Found extras at: $EXTRAS_DIR"

# 2. Create schema using the bundled DDL scripts
echo "[2/7] Creating tables..."
$PSQL -c "CREATE EXTENSION IF NOT EXISTS postgis;"

# Create authority code tables
for sql_file in "$EXTRAS_DIR/GNAF_TableCreation_Scripts/"*create_tables*.sql; do
  if [ -f "$sql_file" ]; then
    echo "  Running: $(basename "$sql_file")"
    $PSQL -f "$sql_file" 2>/dev/null || true
  fi
done

# If no bundled DDL, create tables manually
$PSQL << 'TABLESQL'
-- Authority code tables
CREATE TABLE IF NOT EXISTS state (
  state_pid TEXT PRIMARY KEY,
  date_created DATE,
  date_retired DATE,
  state_name TEXT,
  state_abbreviation TEXT
);

CREATE TABLE IF NOT EXISTS address_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS flat_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS level_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS street_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS street_suffix_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS street_class_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS geocode_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS geocode_reliability_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS geocoded_level_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS locality_class_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS mb_match_code_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);
CREATE TABLE IF NOT EXISTS ps_join_type_aut (code TEXT PRIMARY KEY, name TEXT, description TEXT);

-- Core tables
CREATE TABLE IF NOT EXISTS locality (
  locality_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  locality_name TEXT,
  primary_postcode TEXT,
  locality_class_code TEXT,
  state_pid TEXT,
  gnaf_locality_pid TEXT,
  gnaf_reliability_code SMALLINT
);

CREATE TABLE IF NOT EXISTS locality_alias (
  locality_alias_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  locality_pid TEXT,
  name TEXT,
  postcode TEXT,
  alias_type_code TEXT,
  state_pid TEXT
);

CREATE TABLE IF NOT EXISTS locality_neighbour (
  locality_neighbour_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  locality_pid TEXT,
  neighbour_locality_pid TEXT
);

CREATE TABLE IF NOT EXISTS locality_point (
  locality_point_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  locality_pid TEXT,
  planimetric_accuracy NUMERIC,
  latitude NUMERIC,
  longitude NUMERIC
);

CREATE TABLE IF NOT EXISTS street_locality (
  street_locality_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  street_class_code TEXT,
  street_name TEXT,
  street_type_code TEXT,
  street_suffix_code TEXT,
  locality_pid TEXT,
  gnaf_street_pid TEXT,
  gnaf_street_confidence SMALLINT,
  gnaf_reliability_code SMALLINT
);

CREATE TABLE IF NOT EXISTS street_locality_alias (
  street_locality_alias_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  street_locality_pid TEXT,
  street_name TEXT,
  street_type_code TEXT,
  street_suffix_code TEXT,
  alias_type_code TEXT
);

CREATE TABLE IF NOT EXISTS street_locality_point (
  street_locality_point_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  street_locality_pid TEXT,
  boundary_extent SMALLINT,
  planimetric_accuracy NUMERIC,
  latitude NUMERIC,
  longitude NUMERIC
);

CREATE TABLE IF NOT EXISTS address_site (
  address_site_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  address_type TEXT,
  address_site_name TEXT
);

CREATE TABLE IF NOT EXISTS address_site_geocode (
  address_site_geocode_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  address_site_pid TEXT,
  geocode_site_name TEXT,
  geocode_site_description TEXT,
  geocode_type_code TEXT,
  reliability_code TEXT,
  boundary_extent SMALLINT,
  planimetric_accuracy NUMERIC,
  elevation NUMERIC,
  latitude NUMERIC,
  longitude NUMERIC
);

CREATE TABLE IF NOT EXISTS address_detail (
  address_detail_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  building_name TEXT,
  lot_number_prefix TEXT, lot_number TEXT, lot_number_suffix TEXT,
  flat_type_code TEXT,
  flat_number_prefix TEXT, flat_number NUMERIC, flat_number_suffix TEXT,
  level_type_code TEXT,
  level_number_prefix TEXT, level_number NUMERIC, level_number_suffix TEXT,
  number_first_prefix TEXT, number_first NUMERIC, number_first_suffix TEXT,
  number_last_prefix TEXT, number_last NUMERIC, number_last_suffix TEXT,
  street_locality_pid TEXT,
  locality_pid TEXT,
  alias_principal TEXT,
  postcode TEXT,
  private_street TEXT,
  legal_parcel_id TEXT,
  confidence SMALLINT,
  address_site_pid TEXT,
  level_geocoded_code TEXT,
  property_pid TEXT,
  gnaf_property_pid TEXT,
  primary_secondary TEXT
);

CREATE TABLE IF NOT EXISTS address_default_geocode (
  address_default_geocode_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  address_detail_pid TEXT,
  geocode_type_code TEXT,
  latitude NUMERIC,
  longitude NUMERIC
);

CREATE TABLE IF NOT EXISTS address_mesh_block_2021 (
  address_mesh_block_2021_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  address_detail_pid TEXT,
  mb_match_code TEXT,
  mb_2021_pid TEXT
);

CREATE TABLE IF NOT EXISTS address_alias (
  address_alias_pid TEXT PRIMARY KEY,
  date_created DATE, date_retired DATE,
  address_detail_pid TEXT,
  alias_pid TEXT
);

CREATE TABLE IF NOT EXISTS primary_secondary (
  primary_secondary_pid TEXT PRIMARY KEY,
  primary_pid TEXT,
  secondary_pid TEXT,
  date_created DATE, date_retired DATE,
  ps_join_type_code TEXT,
  ps_join_comment TEXT
);
TABLESQL

echo "  Tables created"

# 3. Import authority code data
echo "[3/7] Importing authority codes..."
AUTH_DIR="$GNAF_DIR/Authority Code"
if [ -d "$AUTH_DIR" ]; then
  for psv in "$AUTH_DIR"/*.psv; do
    TABLE=$(basename "$psv" | sed 's/_AUT_psv.psv/_aut/i; s/_psv\.psv//i' | tr '[:upper:]' '[:lower:]')
    echo "  $TABLE"
    # Skip header line, pipe-delimited
    tail -n +2 "$psv" | $PSQL -c "COPY $TABLE FROM STDIN WITH (FORMAT csv, DELIMITER '|', NULL '', QUOTE E'\x01')" 2>/dev/null || echo "    (skipped)"
  done
fi

# 4. Import state-partitioned data
echo "[4/7] Importing address data (all states)..."
STATES=("ACT" "NSW" "NT" "OT" "QLD" "SA" "TAS" "VIC" "WA")

for STATE in "${STATES[@]}"; do
  STATE_DIR="$GNAF_DIR/Standard/$STATE"
  if [ ! -d "$STATE_DIR" ]; then
    echo "  Skipping $STATE (not found)"
    continue
  fi
  echo "  Importing $STATE..."

  for psv in "$STATE_DIR"/*.psv; do
    BASENAME=$(basename "$psv" | sed "s/${STATE}_//i; s/_psv\.psv//i" | tr '[:upper:]' '[:lower:]')
    # Map common filenames to table names
    TABLE="$BASENAME"
    COUNT=$(tail -n +2 "$psv" | wc -l)
    if [ "$COUNT" -gt 0 ]; then
      tail -n +2 "$psv" | $PSQL -c "COPY $TABLE FROM STDIN WITH (FORMAT csv, DELIMITER '|', NULL '', QUOTE E'\x01')" 2>/dev/null && \
        echo "    $TABLE: $COUNT rows" || echo "    $TABLE: skipped"
    fi
  done
done

# 5. Create indexes
echo "[5/7] Creating indexes..."
$PSQL << 'INDEXSQL'
CREATE INDEX IF NOT EXISTS idx_address_detail_locality ON address_detail(locality_pid);
CREATE INDEX IF NOT EXISTS idx_address_detail_street ON address_detail(street_locality_pid);
CREATE INDEX IF NOT EXISTS idx_address_detail_site ON address_detail(address_site_pid);
CREATE INDEX IF NOT EXISTS idx_address_detail_principal ON address_detail(alias_principal);
CREATE INDEX IF NOT EXISTS idx_address_detail_postcode ON address_detail(postcode);
CREATE INDEX IF NOT EXISTS idx_address_default_geocode_detail ON address_default_geocode(address_detail_pid);
CREATE INDEX IF NOT EXISTS idx_street_locality_locality ON street_locality(locality_pid);
CREATE INDEX IF NOT EXISTS idx_street_locality_name ON street_locality(street_name);
CREATE INDEX IF NOT EXISTS idx_locality_name ON locality(locality_name);
CREATE INDEX IF NOT EXISTS idx_locality_state ON locality(state_pid);
CREATE INDEX IF NOT EXISTS idx_address_site_geocode_site ON address_site_geocode(address_site_pid);
INDEXSQL
echo "  Indexes created"

# 6. Create ADDRESS_VIEW
echo "[6/7] Creating ADDRESS_VIEW..."
$PSQL << 'VIEWSQL'
CREATE OR REPLACE VIEW address_view AS
SELECT
    ad.address_detail_pid,
    ad.street_locality_pid,
    ad.locality_pid,
    ad.building_name,
    ad.lot_number_prefix, ad.lot_number, ad.lot_number_suffix,
    fta.name AS flat_type,
    ad.flat_number_prefix, ad.flat_number, ad.flat_number_suffix,
    lta.name AS level_type,
    ad.level_number_prefix, ad.level_number, ad.level_number_suffix,
    ad.number_first_prefix, ad.number_first, ad.number_first_suffix,
    ad.number_last_prefix, ad.number_last, ad.number_last_suffix,
    sl.street_name,
    sl.street_class_code,
    sl.street_type_code,
    sl.street_suffix_code,
    l.locality_name,
    st.state_abbreviation,
    ad.postcode,
    adg.latitude,
    adg.longitude,
    gta.name AS geocode_type,
    ad.confidence,
    ad.alias_principal,
    ad.primary_secondary,
    ad.legal_parcel_id,
    ad.date_created
FROM address_detail ad
    LEFT JOIN flat_type_aut fta ON ad.flat_type_code = fta.code
    LEFT JOIN level_type_aut lta ON ad.level_type_code = lta.code
    JOIN street_locality sl ON ad.street_locality_pid = sl.street_locality_pid
    JOIN locality l ON ad.locality_pid = l.locality_pid
    LEFT JOIN address_default_geocode adg ON ad.address_detail_pid = adg.address_detail_pid
    LEFT JOIN geocode_type_aut gta ON adg.geocode_type_code = gta.code
    JOIN state st ON l.state_pid = st.state_pid
WHERE ad.confidence > -1;

-- Formatted address helper view (principal addresses only)
CREATE OR REPLACE VIEW address_principals AS
SELECT
    address_detail_pid,
    TRIM(
        COALESCE(flat_type || ' ', '') ||
        COALESCE(flat_number_prefix, '') || COALESCE(CAST(flat_number AS TEXT), '') || COALESCE(flat_number_suffix, '') ||
        CASE WHEN flat_number IS NOT NULL THEN '/' ELSE '' END ||
        COALESCE(number_first_prefix, '') || COALESCE(CAST(number_first AS TEXT), '') || COALESCE(number_first_suffix, '') ||
        CASE WHEN number_last IS NOT NULL THEN '-' || COALESCE(number_last_prefix, '') || CAST(number_last AS TEXT) || COALESCE(number_last_suffix, '') ELSE '' END ||
        ' ' || street_name ||
        COALESCE(' ' || street_type_code, '') ||
        COALESCE(' ' || street_suffix_code, '')
    ) AS street_address,
    locality_name,
    state_abbreviation,
    postcode,
    latitude,
    longitude,
    TRIM(
        COALESCE(flat_type || ' ', '') ||
        COALESCE(flat_number_prefix, '') || COALESCE(CAST(flat_number AS TEXT), '') || COALESCE(flat_number_suffix, '') ||
        CASE WHEN flat_number IS NOT NULL THEN '/' ELSE '' END ||
        COALESCE(number_first_prefix, '') || COALESCE(CAST(number_first AS TEXT), '') || COALESCE(number_first_suffix, '') ||
        CASE WHEN number_last IS NOT NULL THEN '-' || COALESCE(number_last_prefix, '') || CAST(number_last AS TEXT) || COALESCE(number_last_suffix, '') ELSE '' END ||
        ' ' || street_name ||
        COALESCE(' ' || street_type_code, '') ||
        COALESCE(' ' || street_suffix_code, '') ||
        ', ' || locality_name ||
        ' ' || state_abbreviation ||
        ' ' || COALESCE(postcode, '')
    ) AS full_address,
    building_name,
    confidence,
    geocode_type
FROM address_view
WHERE alias_principal = 'P';
VIEWSQL
echo "  Views created"

# 7. Verify
echo "[7/7] Verifying import..."
$PSQL << 'VERIFYSQL'
SELECT 'Total addresses' AS metric, COUNT(*)::TEXT AS value FROM address_detail
UNION ALL
SELECT 'Principal addresses', COUNT(*)::TEXT FROM address_detail WHERE alias_principal = 'P'
UNION ALL
SELECT 'States', COUNT(*)::TEXT FROM state
UNION ALL
SELECT 'Localities', COUNT(*)::TEXT FROM locality
UNION ALL
SELECT 'Streets', COUNT(*)::TEXT FROM street_locality
UNION ALL
SELECT 'Geocoded addresses', COUNT(*)::TEXT FROM address_default_geocode
UNION ALL
SELECT 'Database size', pg_size_pretty(pg_database_size('fiberco-naf'));
VERIFYSQL

echo ""
echo "=== G-NAF Import Complete ==="
