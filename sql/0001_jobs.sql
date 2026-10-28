-- Written by hand. This file is the schema authority (DEC-005/006).
-- Scope: local foundation, before identity and audio processing integration.
CREATE TABLE public.jobs (
    id uuid PRIMARY KEY,
    idempotency_key uuid NOT NULL UNIQUE,
    fingerprint text NOT NULL CHECK (fingerprint ~ '^[a-f0-9]{64}$'),
    audio_sha256 text NOT NULL CHECK (audio_sha256 ~ '^[a-f0-9]{64}$'),
    status text NOT NULL CHECK (status IN ('awaiting_audio', 'cancelled')),
    source_language text NOT NULL CHECK (source_language ~ '^[a-z]{2,3}$'),
    target_language text NOT NULL CHECK (target_language ~ '^[a-z]{2,3}$'),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL CHECK (updated_at >= created_at)
);

COMMENT ON TABLE public.jobs IS
    'Local job reservations. Add authenticated ownership with manual SQL before enabling multi-user access.';
