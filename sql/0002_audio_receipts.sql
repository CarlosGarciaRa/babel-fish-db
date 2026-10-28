-- Manual, additive evolution. Existing reservations and idempotency keys survive.
ALTER TABLE public.jobs DROP CONSTRAINT jobs_status_check;
ALTER TABLE public.jobs ADD CONSTRAINT jobs_status_check
    CHECK (status IN ('awaiting_audio', 'audio_received', 'cancelled', 'expired'));
ALTER TABLE public.jobs ADD COLUMN audio_started_at timestamptz;
ALTER TABLE public.jobs ADD COLUMN audio_file_id uuid;
ALTER TABLE public.jobs ADD COLUMN audio_bytes bigint CHECK (audio_bytes > 0);
ALTER TABLE public.jobs ADD COLUMN audio_duration_ms integer CHECK (audio_duration_ms > 0);
ALTER TABLE public.jobs ADD CONSTRAINT jobs_audio_receipt_check CHECK (
    status <> 'audio_received' OR
    (audio_started_at IS NOT NULL AND audio_file_id IS NOT NULL AND audio_bytes IS NOT NULL AND audio_duration_ms IS NOT NULL)
);
CREATE INDEX jobs_audio_expiration ON public.jobs (audio_started_at)
    WHERE status IN ('awaiting_audio', 'audio_received') AND audio_started_at IS NOT NULL;
