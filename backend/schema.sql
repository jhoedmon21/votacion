-- VotoPaucarpata Quick Count & Map System — PostgreSQL Schema
-- SQLite-compatible fallback uses the same DDL (types auto-coerced).

-- Venues (Colegios / Locales de Votación)
CREATE TABLE IF NOT EXISTS venues (
    id            SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    sector        TEXT NOT NULL,          -- Ciudad de Dios, Miguel Grau, Israel, Campo Marte, 15 de Agosto
    address       TEXT,
    latitude      DOUBLE PRECISION NOT NULL,
    longitude     DOUBLE PRECISION NOT NULL,
    total_tables  INTEGER NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Electoral Tables (Mesas)
CREATE TABLE IF NOT EXISTS tables (
    id              SERIAL PRIMARY KEY,
    venue_id        INTEGER NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
    numero_mesa     TEXT NOT NULL UNIQUE,           -- 6-digit mesa number (kept as TEXT to preserve leading zeros)
    processed       BOOLEAN NOT NULL DEFAULT FALSE,
    requires_review BOOLEAN NOT NULL DEFAULT FALSE,
    status          TEXT NOT NULL DEFAULT 'pending', -- pending | processed | requires_review | validated
    ocr_confidence  DOUBLE PRECISION,
    image_url       TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- District Candidates (Alcaldía de Paucarpata)
CREATE TABLE IF NOT EXISTS district_candidates (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    party       TEXT,
    color       TEXT NOT NULL DEFAULT '#3b82f6',
    symbol      TEXT,
    photo_url   TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Regional Candidates (Gobierno Regional de Arequipa)
CREATE TABLE IF NOT EXISTS regional_candidates (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    party       TEXT,
    color       TEXT NOT NULL DEFAULT '#8b5cf6',
    symbol      TEXT,
    photo_url   TEXT,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Voting Records (Actas) — normalized candidate votes
CREATE TABLE IF NOT EXISTS records (
    id                  SERIAL PRIMARY KEY,
    table_id            INTEGER NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
    candidate_type      TEXT NOT NULL,               -- 'district' | 'regional'
    candidate_id        INTEGER NOT NULL,
    votes               INTEGER NOT NULL DEFAULT 0,
    verified            BOOLEAN NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Acta metadata (blank/null/impugned counts belong to the whole mesa, not a candidate)
CREATE TABLE IF NOT EXISTS acta_metadata (
    id                SERIAL PRIMARY KEY,
    table_id          INTEGER NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
    votos_blancos     INTEGER NOT NULL DEFAULT 0,
    votos_nulos       INTEGER NOT NULL DEFAULT 0,
    votos_impugnados  INTEGER NOT NULL DEFAULT 0,
    total_electores   INTEGER,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_tables_venue      ON tables(venue_id);
CREATE INDEX IF NOT EXISTS idx_tables_numero     ON tables(numero_mesa);
CREATE INDEX IF NOT EXISTS idx_tables_status     ON tables(status);
CREATE INDEX IF NOT EXISTS idx_records_table     ON records(table_id);
CREATE INDEX IF NOT EXISTS idx_records_candidate ON records(candidate_type, candidate_id);
CREATE INDEX IF NOT EXISTS idx_meta_table        ON acta_metadata(table_id);