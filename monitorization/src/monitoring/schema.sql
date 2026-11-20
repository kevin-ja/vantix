-- Esquema del monitoreo (doc §8.3). Única fuente: lo ejecuta Postgres al inicializar un volumen vacío
-- (docker-entrypoint-initdb.d) y el backend antes de escribir (idempotente: IF NOT EXISTS).
CREATE TABLE IF NOT EXISTS runs (
    run_id        BIGSERIAL PRIMARY KEY,
    dataset       TEXT        NOT NULL CHECK (dataset IN ('benchmark', 'new')),
    model_version TEXT        NOT NULL,
    ingest_date   DATE        NOT NULL,
    snapshot_date DATE        NOT NULL,
    window_days   INT         NOT NULL,
    n_rows        BIGINT      NOT NULL,
    n_users       BIGINT,
    git_commit    TEXT        NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS data_quality (
    run_id  BIGINT           NOT NULL REFERENCES runs ON DELETE CASCADE,
    metric  TEXT             NOT NULL,
    value   DOUBLE PRECISION NOT NULL,
    unit    TEXT             NOT NULL,
    level   TEXT             NOT NULL,
    alert   BOOLEAN          NOT NULL,
    details JSONB            NOT NULL,
    PRIMARY KEY (run_id, metric)
);
CREATE TABLE IF NOT EXISTS data_drift (
    run_id    BIGINT           NOT NULL REFERENCES runs ON DELETE CASCADE,
    feature   TEXT             NOT NULL,
    psi       DOUBLE PRECISION NOT NULL,
    psi_level TEXT             NOT NULL,
    ks        DOUBLE PRECISION NOT NULL,
    ks_pvalue DOUBLE PRECISION NOT NULL,
    ks_level  TEXT             NOT NULL,
    alert     BOOLEAN          NOT NULL,
    PRIMARY KEY (run_id, feature)
);
