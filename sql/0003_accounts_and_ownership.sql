-- BF-35 / US-014: internal identity bound to a verified Firebase UID, and per-owner jobs.
-- Manual and additive (DEC-005/006). Passwords never live here: Firebase Authentication owns them.
--
-- This migration assumes no job rows exist yet (the application has never run). If rows do
-- exist, `ALTER COLUMN owner_id SET NOT NULL` fails on purpose: legacy rows have no owner and
-- must be resolved by an explicit, reviewed decision, never assigned to the first account.
CREATE TABLE public.accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    firebase_uid text NOT NULL UNIQUE CHECK (firebase_uid <> ''),
    email text CHECK (email IS NULL OR email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL CHECK (updated_at >= created_at)
);

COMMENT ON TABLE public.accounts IS
    'Internal Babel Fish identity bound to a verified Firebase UID. The UID is the stable key; email never identifies an account and never links two methods.';

ALTER TABLE public.jobs DROP CONSTRAINT jobs_idempotency_key_key;
ALTER TABLE public.jobs ADD COLUMN owner_id uuid;
ALTER TABLE public.jobs ALTER COLUMN owner_id SET NOT NULL;
ALTER TABLE public.jobs ADD CONSTRAINT jobs_owner_id_fkey
    FOREIGN KEY (owner_id) REFERENCES public.accounts (id) ON DELETE RESTRICT;

-- Idempotency is scoped to the owner: a key invented by one account can never replay
-- or capture another account's reservation.
CREATE UNIQUE INDEX jobs_owner_idempotency_key_key
    ON public.jobs (owner_id, idempotency_key);
CREATE INDEX jobs_owner_id_created_at_idx
    ON public.jobs (owner_id, created_at DESC);

COMMENT ON COLUMN public.jobs.owner_id IS
    'Resolved from the verified Firebase ID token, never from a client-supplied identifier.';
