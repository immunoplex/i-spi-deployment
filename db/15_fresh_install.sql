-- =============================================================================
-- 15_fresh_install.sql -- adjustments a NEW database needs on top of the
-- production-derived 10_ispi_core.sql. Each one is listed in db/MANIFEST.md.
-- =============================================================================

-- curve_lookup rejects the placeholder project 0 (its column default). In
-- production the check reads project_id >= 16 because projects 1-15 predate
-- the curve registry; a new database numbers its projects from 1.
ALTER TABLE madi_results.curve_lookup DROP CONSTRAINT curve_lookup_real_project_chk;
ALTER TABLE madi_results.curve_lookup
  ADD CONSTRAINT curve_lookup_real_project_chk CHECK (project_id > 0);
