-- Forward-only migration for the live Recipe Intelligence ingestion schema.
-- Historical 2026-08-03 bootstrap/remote-history files must not be replayed.
-- The fingerprint is computed inside PostgreSQL to protect all clients, including
-- clients that do not yet know about this new column.
--
-- Identity:
--   inbox_id + evidence_role + evidence_type + trimmed locator + trimmed resolver
--   + (trimmed content_text if present, otherwise canonical JSONB payload).
-- Runtime/provider metadata in payload does not create a duplicate when the
-- source text is unchanged. Meaningful source-content changes receive a new hash.
-- confidence_score, is_primary and timestamps are intentionally not in the key.

BEGIN;

ALTER TABLE public.recipe_inbox_evidence
  ADD COLUMN evidence_fingerprint text;

CREATE FUNCTION private.set_recipe_evidence_fingerprint_v1()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $fingerprint$
BEGIN
  NEW.evidence_fingerprint := encode(
    sha256(
      convert_to(
        jsonb_build_array(
          NEW.inbox_id::text,
          NEW.evidence_role,
          NEW.evidence_type,
          nullif(btrim(NEW.locator), ''),
          nullif(btrim(NEW.resolver), ''),
          CASE
            WHEN nullif(btrim(NEW.content_text), '') IS NOT NULL
            THEN 'text'
            ELSE 'payload'
          END,
          CASE
            WHEN nullif(btrim(NEW.content_text), '') IS NOT NULL
            THEN to_jsonb(btrim(NEW.content_text))
            ELSE NEW.payload
          END
        )::text,
        'UTF8'
      )
    ),
    'hex'
  );
  RETURN NEW;
END;
$fingerprint$;

-- Do not expose the helper to the Data API or general roles.
REVOKE ALL ON FUNCTION private.set_recipe_evidence_fingerprint_v1() FROM PUBLIC;

CREATE TRIGGER trg_recipe_inbox_evidence_fingerprint
  BEFORE INSERT OR UPDATE
  ON public.recipe_inbox_evidence
  FOR EACH ROW
  EXECUTE FUNCTION private.set_recipe_evidence_fingerprint_v1();

-- The trigger calculates this for every existing row. No evidence is deleted or merged.
UPDATE public.recipe_inbox_evidence
SET evidence_fingerprint = NULL;

ALTER TABLE public.recipe_inbox_evidence
  ALTER COLUMN evidence_fingerprint SET NOT NULL;

ALTER TABLE public.recipe_inbox_evidence
  ADD CONSTRAINT recipe_inbox_evidence_fingerprint_format_check
  CHECK (evidence_fingerprint ~ '^[0-9a-f]{64}$');

CREATE UNIQUE INDEX ux_recipe_inbox_evidence_fingerprint
  ON public.recipe_inbox_evidence (evidence_fingerprint);

COMMIT;
