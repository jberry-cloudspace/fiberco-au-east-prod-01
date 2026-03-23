"""FiberCo G-NAF Address API"""
import os, time
from contextlib import asynccontextmanager
from typing import Optional

import psycopg2
from psycopg2 import pool
from fastapi import FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware

DB = {"host": "fiberco-naf-db", "port": 5432, "user": "app", "password": "app", "dbname": "fiberco-naf"}

ABBREVS = {
    "ST": "STREET", "RD": "ROAD", "AVE": "AVENUE", "AV": "AVENUE",
    "DR": "DRIVE", "PL": "PLACE", "CT": "COURT", "CL": "CLOSE",
    "CR": "CRESCENT", "CRES": "CRESCENT", "LN": "LANE", "TCE": "TERRACE",
    "TER": "TERRACE", "HWY": "HIGHWAY", "BVD": "BOULEVARD", "BLVD": "BOULEVARD",
    "PKY": "PARKWAY", "PDE": "PARADE", "GR": "GROVE", "CCT": "CIRCUIT",
    "CIR": "CIRCUIT", "ESP": "ESPLANADE",
}

def expand(text):
    return " ".join(ABBREVS.get(w, w) for w in text.split())

db_pool = None

RESULT_COLUMNS = """pid, street_address, building_name, flat_type, flat_number, level_type, level_number,
    number_first, number_last, street_name, street_type_code, street_suffix_code, street_class_code,
    locality_name, state, state_name, postcode, lat, lng, 
    legal_parcel_id, lot_number, lot_number_prefix, lot_number_suffix,
    parcel_lot, plan_type, plan_number,
    confidence, locality_class_code, primary_secondary,
    property_pid, gnaf_property_pid, address_type, address_site_name,
    location_description, date_created, date_last_modified,
    CASE
        WHEN flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN') THEN 'commercial'
        WHEN flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION') THEN 'infrastructure'
        WHEN flat_type IN ('UNIT','APARTMENT','FLAT','VILLA','TOWNHOUSE','HOUSE','DUPLEX','COTTAGE','PENTHOUSE','STUDIO','MAISONETTE','STRATA UNIT','LOFT','ROOM') THEN 'residential'
        WHEN flat_type IS NOT NULL THEN 'other'
        WHEN address_type = 'R' THEN 'rural'
        ELSE 'residential'
    END AS property_class"""

@asynccontextmanager
async def lifespan(app):
    global db_pool
    db_pool = pool.ThreadedConnectionPool(2, 10, **DB)
    yield
    db_pool.closeall()

app = FastAPI(title="FiberCo G-NAF API", version="1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

def query_db(sql, params=None):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [d[0] for d in cur.description]
            rows = []
            for row in cur.fetchall():
                d = {}
                for k, v in zip(cols, row):
                    if v is not None:
                        d[k] = v
                rows.append(d)
            return rows
    finally:
        db_pool.putconn(conn)


@app.get("/api/address/autocomplete")
def autocomplete(
    q: str = Query(..., min_length=3),
    limit: int = Query(1000, ge=1),
    state: Optional[str] = Query(None),
    postcode: Optional[str] = Query(None),
    property_class: Optional[str] = Query(None, description="Filter: residential, commercial, infrastructure, rural"),
):
    """Address autocomplete. Searches full address (including unit/level) and street-level.
    Typing '123 pitt st sydney' returns ALL units at that address."""
    start = time.perf_counter()
    raw = " ".join(q.upper().strip().replace(",", " ").split())
    expanded = expand(raw)

    filters = []
    params = []
    if state:
        filters.append("state = %s")
        params.append(state.upper())
    if postcode:
        filters.append("postcode = %s")
        params.append(postcode)
    if property_class:
        pc = property_class.lower()
        if pc == 'commercial':
            filters.append("flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN')")
        elif pc == 'infrastructure':
            filters.append("flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION')")
        elif pc == 'residential':
            filters.append("(flat_type IS NULL OR flat_type IN ('UNIT','APARTMENT','FLAT','VILLA','TOWNHOUSE','HOUSE','DUPLEX','COTTAGE','PENTHOUSE','STUDIO','MAISONETTE','STRATA UNIT','LOFT','ROOM'))")
        elif pc == 'rural':
            filters.append("address_type = 'R'")

    filter_sql = (" AND " + " AND ".join(filters)) if filters else ""

    # If query starts with unit/level keyword, search full (includes unit prefix)
    # Otherwise search street-level to return ALL units at that address
    unit_kw = ('SUITE','UNIT','FLAT','SHOP','LEVEL','ROOM','OFFICE','APT','APARTMENT','VILLA','TOWNHOUSE','LOT','FACTORY','WAREHOUSE','SHED','KIOSK','STUDIO')
    first_word = expanded.split()[0] if expanded else ''
    # When filtering by property_class, use search_street but include all flat_types at matched addresses
    search_col = "search_full" if first_word in unit_kw else "search_street"

    rows = None
    for term in [expanded, raw]:
        q_params = [term + "%"] + params + [limit]
        rows = query_db(f"""
            SELECT {RESULT_COLUMNS}
            FROM gnaf.autocomplete
            WHERE {search_col} LIKE %s{filter_sql}
            ORDER BY street_address
            LIMIT %s
        """, q_params)
        if rows:
            break

    elapsed = (time.perf_counter() - start) * 1000
    return {"query": q, "count": len(rows), "time_ms": round(elapsed, 2), "results": rows}



@app.get("/api/address/plan")
def plan_search(
    plan: str = Query(..., min_length=2, description="Plan number e.g. SP82939, DP1027838"),
    limit: int = Query(100, ge=1),
):
    """Search all addresses on a strata plan, deposited plan, etc."""
    start = time.perf_counter()
    p = plan.upper().strip()
    plan_type = plan_number = None
    for prefix in ('SP', 'DP', 'RP', 'CP', 'PS', 'PC'):
        if p.startswith(prefix):
            plan_type = prefix
            plan_number = p[len(prefix):].strip()
            break
    if plan_type and plan_number:
        rows = query_db(f"SELECT {RESULT_COLUMNS} FROM gnaf.autocomplete WHERE plan_type = %s AND plan_number = %s ORDER BY street_address LIMIT %s", (plan_type, plan_number, limit))
    else:
        rows = query_db(f"SELECT {RESULT_COLUMNS} FROM gnaf.autocomplete WHERE legal_parcel_id LIKE %s ORDER BY street_address LIMIT %s", ('%' + p + '%', limit))
    elapsed = (time.perf_counter() - start) * 1000
    return {"plan": plan, "plan_type": plan_type, "plan_number": plan_number, "count": len(rows), "time_ms": round(elapsed, 2), "results": rows}

@app.get("/api/address/{pid}")
def get_address(pid: str):
    rows = query_db(f"SELECT {RESULT_COLUMNS} FROM gnaf.autocomplete WHERE pid = %s", (pid,))
    if not rows:
        raise HTTPException(404, "Address not found")
    return rows[0]


@app.get("/api/locality/addresses")
def locality_addresses(
    locality: str = Query(...), state: Optional[str] = Query(None),
    limit: int = Query(1000, ge=1), offset: int = Query(0, ge=0),
    property_class: Optional[str] = Query(None, description="Filter: residential, commercial, infrastructure, rural"),
):
    conditions = ["locality_name = %s"]
    params = [locality.upper()]
    if state:
        conditions.append("state = %s")
        params.append(state.upper())
    if property_class:
        pc = property_class.lower()
        if pc == 'commercial':
            conditions.append("flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN')")
        elif pc == 'infrastructure':
            conditions.append("flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION')")
        elif pc == 'residential':
            conditions.append("(flat_type IS NULL OR flat_type IN ('UNIT','APARTMENT','FLAT','VILLA','TOWNHOUSE','HOUSE','DUPLEX','COTTAGE','PENTHOUSE','STUDIO','MAISONETTE','STRATA UNIT','LOFT','ROOM'))")
        elif pc == 'rural':
            conditions.append("address_type = 'R'")
    where = " AND ".join(conditions)
    params.extend([limit, offset])
    rows = query_db(f"SELECT {RESULT_COLUMNS} FROM gnaf.autocomplete WHERE {where} ORDER BY street_address LIMIT %s OFFSET %s", params)
    return {"locality": locality.upper(), "count": len(rows), "results": rows}


@app.get("/api/address/near")
def addresses_near(
    lat: float = Query(...), lng: float = Query(...),
    radius: int = Query(500, ge=1, le=50000), limit: int = Query(20, ge=1, le=200),
):
    d_lat, d_lng = radius/111000, radius/(111000*0.7)
    rows = query_db(f"""
        SELECT {RESULT_COLUMNS},
               ROUND((SQRT(POW((lat-%s)*111000,2)+POW((lng-%s)*111000*0.7,2)))::numeric,1) AS distance_m
        FROM gnaf.autocomplete
        WHERE lat BETWEEN %s AND %s AND lng BETWEEN %s AND %s
        ORDER BY POW(lat-%s,2)+POW(lng-%s,2) LIMIT %s
    """, (lat, lng, lat-d_lat, lat+d_lat, lng-d_lng, lng+d_lng, lat, lng, limit))
    return {"lat": lat, "lng": lng, "radius_m": radius, "count": len(rows), "results": rows}


@app.get("/api/stats")
def stats():
    return query_db("SELECT (SELECT COUNT(*) FROM gnaf.address_detail) AS total, (SELECT COUNT(*) FROM gnaf.autocomplete) AS searchable, (SELECT COUNT(*) FROM gnaf.locality) AS localities, (SELECT pg_size_pretty(pg_database_size('fiberco-naf'))) AS db_size")[0]

@app.get("/health")
def health():
    return {"status": "ok", "service": "fiberco-gnaf-api"}


@app.get("/api/address/plan")
def plan_search(
    plan: str = Query(..., min_length=2, description="Plan number e.g. SP82939, DP1027838, RP227041"),
    limit: int = Query(100, ge=1),
):
    """Search all addresses on a strata plan, deposited plan, or other plan number."""
    start = time.perf_counter()
    p = plan.upper().strip()

    # Parse plan type and number from input like "SP82939" or "DP 1027838"
    plan_type = None
    plan_number = None
    for prefix in ('SP', 'DP', 'RP', 'CP', 'PS', 'PC'):
        if p.startswith(prefix):
            plan_type = prefix
            plan_number = p[len(prefix):].strip()
            break

    if not plan_type or not plan_number:
        # Try raw match against legal_parcel_id
        q_params = ['%' + p + '%', limit]
        rows = query_db(f"""
            SELECT {RESULT_COLUMNS}
            FROM gnaf.autocomplete
            WHERE legal_parcel_id LIKE %s
            ORDER BY street_address
            LIMIT %s
        """, q_params)
    else:
        q_params = [plan_type, plan_number, limit]
        rows = query_db(f"""
            SELECT {RESULT_COLUMNS}
            FROM gnaf.autocomplete
            WHERE plan_type = %s AND plan_number = %s
            ORDER BY street_address
            LIMIT %s
        """, q_params)

    elapsed = (time.perf_counter() - start) * 1000
    return {"plan": plan, "plan_type": plan_type, "plan_number": plan_number, "count": len(rows), "time_ms": round(elapsed, 2), "results": rows}


@app.get("/api/tam/analyse")
def tam_analyse(
    locality: Optional[str] = Query(None, description="Suburb/locality name e.g. RHODES"),
    street: Optional[str] = Query(None, description="Street name e.g. WALKER"),
    postcode: Optional[str] = Query(None),
    state: Optional[str] = Query(None),
    plan: Optional[str] = Query(None, description="Plan number e.g. SP82939"),
    lat: Optional[float] = Query(None, description="Centre latitude for radius search"),
    lng: Optional[float] = Query(None, description="Centre longitude for radius search"),
    radius: Optional[int] = Query(None, ge=100, le=50000, description="Radius in metres (requires lat/lng)"),
    property_class: Optional[str] = Query(None, description="Filter: residential, commercial, infrastructure, rural"),
):
    """Total Addressable Market analysis.
    
    Returns deep breakdown of all dwellings in an area: building density,
    unit counts per building, strata plans, address types, and full dwelling list.
    Search by locality, street, postcode, plan, or geographic radius.
    """
    start = time.perf_counter()

    conditions = []
    params = []

    if locality:
        conditions.append("locality_name = %s")
        params.append(locality.upper())
    if street:
        expanded_street = expand(street.upper())
        conditions.append("street_name = %s")
        params.append(expanded_street)
    if postcode:
        conditions.append("postcode = %s")
        params.append(postcode)
    if state:
        conditions.append("state = %s")
        params.append(state.upper())
    if plan:
        p = plan.upper().strip()
        for prefix in ('SP', 'DP', 'RP', 'CP', 'PS', 'PC'):
            if p.startswith(prefix):
                conditions.append("plan_type = %s AND plan_number = %s")
                params.extend([prefix, p[len(prefix):].strip()])
                break
    if lat is not None and lng is not None and radius:
        d_lat = radius / 111000
        d_lng = radius / (111000 * 0.7)
        conditions.append("lat BETWEEN %s AND %s AND lng BETWEEN %s AND %s")
        params.extend([lat - d_lat, lat + d_lat, lng - d_lng, lng + d_lng])

    if property_class:
        pc = property_class.lower()
        if pc == 'commercial':
            conditions.append("flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN')")
        elif pc == 'infrastructure':
            conditions.append("flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION')")
        elif pc == 'residential':
            conditions.append("(flat_type IS NULL OR flat_type IN ('UNIT','APARTMENT','FLAT','VILLA','TOWNHOUSE','HOUSE','DUPLEX','COTTAGE','PENTHOUSE','STUDIO','MAISONETTE','STRATA UNIT','LOFT','ROOM'))")
        elif pc == 'rural':
            conditions.append("address_type = 'R'")

    if not conditions:
        raise HTTPException(400, "At least one filter required: locality, street, postcode, state, plan, or lat/lng/radius")

    where = " AND ".join(conditions)

    # 1. Summary stats
    summary = query_db(f"""
        SELECT
            COUNT(*) AS total_addresses,
            COUNT(*) FILTER (WHERE primary_secondary = 'P') AS primary_addresses,
            COUNT(*) FILTER (WHERE primary_secondary = 'S') AS secondary_units,
            COUNT(*) FILTER (WHERE primary_secondary IS NULL OR primary_secondary = '') AS unclassified,
            COUNT(*) FILTER (WHERE address_type = 'UN') AS unit_type,
            COUNT(*) FILTER (WHERE address_type = 'UR') AS urban_residential_type,
            COUNT(*) FILTER (WHERE address_type = 'R') AS rural_type,
            COUNT(*) FILTER (WHERE flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN')) AS commercial_count,
            COUNT(*) FILTER (WHERE flat_type IN ('UNIT','APARTMENT','FLAT','VILLA','TOWNHOUSE','HOUSE','DUPLEX','COTTAGE','PENTHOUSE','STUDIO','MAISONETTE','STRATA UNIT','LOFT','ROOM') OR flat_type IS NULL) AS residential_count,
            COUNT(*) FILTER (WHERE flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION')) AS infrastructure_count,
            COUNT(DISTINCT COALESCE(gnaf_property_pid, pid)) AS unique_properties,
            COUNT(DISTINCT NULLIF(plan_type || plan_number, '')) AS unique_plans,
            COUNT(DISTINCT street_name || COALESCE(street_type_code,'')) AS unique_streets,
            COUNT(DISTINCT locality_name) AS unique_localities,
            COUNT(DISTINCT postcode) AS unique_postcodes,
            MIN(lat) AS bbox_south, MAX(lat) AS bbox_north,
            MIN(lng) AS bbox_west, MAX(lng) AS bbox_east,
            AVG(lat) AS centre_lat, AVG(lng) AS centre_lng
        FROM gnaf.autocomplete
        WHERE {where}
    """, params)[0]

    # 2. Buildings (grouped by street number + street + plan)
    buildings = query_db(f"""
        SELECT
            number_first, number_last, street_name, street_type_code, street_suffix_code,
            locality_name, state, postcode,
            plan_type, plan_number, legal_parcel_id,
            building_name,
            COUNT(*) AS total_dwellings,
            COUNT(*) FILTER (WHERE primary_secondary = 'P') AS primary_count,
            COUNT(*) FILTER (WHERE primary_secondary = 'S') AS unit_count,
            COUNT(*) FILTER (WHERE address_type = 'UN') AS units_residential,
            COUNT(*) FILTER (WHERE address_type = 'UR') AS standalone_residential,
            COUNT(*) FILTER (WHERE flat_type IN ('SHOP','SUITE','OFFICE','FACTORY','KIOSK','WAREHOUSE','STORE','TENANCY','STALL','SHOWROOM','AUTOMATED TELLER MACHINE','WORKSHOP','SIGN')) AS commercial_units,
            COUNT(*) FILTER (WHERE flat_type IN ('CARSPACE','CARPARK','GARAGE','MARINE BERTH','BOATSHED','ANTENNA','SUBSTATION')) AS infrastructure_units,
            string_agg(DISTINCT flat_type, ',' ORDER BY flat_type) AS flat_types,
            MIN(lat) AS lat, MIN(lng) AS lng,
            CASE
                WHEN COUNT(*) FILTER (WHERE primary_secondary = 'S') > 50 THEN 'large-mdu'
                WHEN COUNT(*) FILTER (WHERE primary_secondary = 'S') > 10 THEN 'medium-mdu'
                WHEN COUNT(*) FILTER (WHERE primary_secondary = 'S') > 1 THEN 'small-mdu'
                ELSE 'sdu'
            END AS building_class
        FROM gnaf.autocomplete
        WHERE {where}
        GROUP BY number_first, number_last, street_name, street_type_code, street_suffix_code,
                 locality_name, state, postcode, plan_type, plan_number, legal_parcel_id, building_name
        ORDER BY total_dwellings DESC
    """, params)

    # 3. Building class summary
    class_summary = {}
    for b in buildings:
        cls = b['building_class']
        if cls not in class_summary:
            class_summary[cls] = {'count': 0, 'total_dwellings': 0}
        class_summary[cls]['count'] += 1
        class_summary[cls]['total_dwellings'] += b['total_dwellings']

    # 4. Street-level summary
    streets = query_db(f"""
        SELECT
            street_name, street_type_code, locality_name, postcode,
            COUNT(*) AS total_addresses,
            COUNT(DISTINCT COALESCE(plan_type || plan_number, number_first::TEXT || street_name)) AS buildings,
            COUNT(*) FILTER (WHERE primary_secondary = 'S') AS total_units,
            COUNT(*) FILTER (WHERE address_type = 'UN') AS residential_units,
            ROUND(AVG(lat)::numeric, 6) AS lat, ROUND(AVG(lng)::numeric, 6) AS lng
        FROM gnaf.autocomplete
        WHERE {where}
        GROUP BY street_name, street_type_code, locality_name, postcode
        ORDER BY total_addresses DESC
    """, params)

    # 5. Strata plan breakdown
    plans = query_db(f"""
        SELECT
            plan_type, plan_number,
            MIN(street_address) AS primary_address,
            MIN(locality_name) AS locality,
            MIN(postcode) AS postcode,
            COUNT(*) AS total_lots,
            COUNT(*) FILTER (WHERE primary_secondary = 'S') AS units,
            COUNT(*) FILTER (WHERE primary_secondary = 'P') AS common_property,
            MIN(lat) AS lat, MIN(lng) AS lng
        FROM gnaf.autocomplete
        WHERE {where} AND plan_type IS NOT NULL
        GROUP BY plan_type, plan_number
        ORDER BY total_lots DESC
    """, params)

    elapsed = (time.perf_counter() - start) * 1000

    return {
        "time_ms": round(elapsed, 2),
        "filters": {
            "locality": locality, "street": street, "postcode": postcode,
            "state": state, "plan": plan, "property_class": property_class,
            "geo": {"lat": lat, "lng": lng, "radius_m": radius} if lat else None,
        },
        "summary": summary,
        "building_classification": {
            "large_mdu": class_summary.get('large-mdu', {'count': 0, 'total_dwellings': 0}),
            "medium_mdu": class_summary.get('medium-mdu', {'count': 0, 'total_dwellings': 0}),
            "small_mdu": class_summary.get('small-mdu', {'count': 0, 'total_dwellings': 0}),
            "sdu": class_summary.get('sdu', {'count': 0, 'total_dwellings': 0}),
            "description": {
                "large_mdu": "Multi-dwelling unit: 50+ units (high-rise, large complex)",
                "medium_mdu": "Multi-dwelling unit: 11-50 units (mid-rise, townhouse complex)",
                "small_mdu": "Multi-dwelling unit: 2-10 units (duplex, small block)",
                "sdu": "Single dwelling unit (house, standalone)"
            }
        },
        "streets": streets,
        "strata_plans": plans,
        "buildings": buildings,
    }
