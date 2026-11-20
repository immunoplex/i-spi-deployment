-- =============================================================================
-- tests/e2e/check.sql -- after the e2e fit job: the worker must have written
-- complete frequentist results for both seeded curves. Raises (and so fails
-- psql with ON_ERROR_STOP) on the first missing piece; prints counts otherwise.
-- Usage: psql -v ON_ERROR_STOP=1 -v job_id=<id> -f check.sql
-- =============================================================================
\set ON_ERROR_STOP 1
CREATE TEMP TABLE e2e_curves AS
SELECT curve_id FROM madi_results.curve_lookup WHERE study_accession = 'E2E' AND experiment_accession = 'IGG';
CREATE TEMP TABLE e2e_job AS SELECT :'job_id'::text AS job_id;

DO $$
DECLARE n int; n2 int; m text;
BEGIN
  SELECT count(*) INTO n FROM e2e_curves;
  IF n <> 2 THEN RAISE EXCEPTION 'expected 2 seeded curves, found %', n; END IF;

  SELECT count(*), max(r.manifest ->> 'version') INTO n, m
    FROM madi_results.calib_run r JOIN e2e_job j USING (job_id);
  IF n <> 1 THEN RAISE EXCEPTION 'calib_run: % rows for the job', n; END IF;
  IF m IS NULL THEN RAISE EXCEPTION 'calib_run: no release manifest recorded'; END IF;

  SELECT count(DISTINCT f.curve_id) INTO n FROM madi_results.calib_fit f
   WHERE f.curve_id IN (SELECT curve_id FROM e2e_curves) AND f.method = 'frequentist' AND f.is_best;
  IF n <> 2 THEN RAISE EXCEPTION 'calib_fit: best model for % of 2 curves', n; END IF;

  SELECT count(*) INTO n FROM madi_results.calib_param
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n = 0 THEN RAISE EXCEPTION 'calib_param: no rows'; END IF;

  SELECT count(*) INTO n FROM madi_results.calib_grid
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n = 0 THEN RAISE EXCEPTION 'calib_grid: no rows'; END IF;

  SELECT count(*) INTO n FROM madi_results.calib_diagnostics
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n <> 2 THEN RAISE EXCEPTION 'calib_diagnostics: % rows, expected 2', n; END IF;

  SELECT count(*), count(predicted_concentration) INTO n, n2 FROM madi_results.calib_samples
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n <> 8 THEN RAISE EXCEPTION 'calib_samples: % rows, expected 8', n; END IF;
  IF n2 < 6 THEN RAISE EXCEPTION 'calib_samples: only % of 8 samples have a concentration', n2; END IF;

  -- standards carry the stored estimates (calib schema 0.7.0)
  SELECT count(*), count(predicted_log10_concentration) INTO n, n2 FROM madi_results.calib_standards
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n <> 32 THEN RAISE EXCEPTION 'calib_standards: % rows, expected 32', n; END IF;
  IF n2 < 24 THEN RAISE EXCEPTION 'calib_standards: only % of 32 points have an estimate', n2; END IF;

  SELECT count(*) INTO n FROM madi_results.calib_blanks
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n <> 4 THEN RAISE EXCEPTION 'calib_blanks: % rows, expected 4', n; END IF;

  -- controls are estimated right after the fit (i-spi-compute 1.1)
  SELECT count(*), count(final_concentration) INTO n, n2 FROM madi_results.calib_controls
   WHERE curve_id IN (SELECT curve_id FROM e2e_curves) AND method = 'frequentist';
  IF n <> 8 THEN RAISE EXCEPTION 'calib_controls: % rows, expected 8', n; END IF;
  IF n2 < 8 THEN RAISE EXCEPTION 'calib_controls: only % of 8 controls have a concentration', n2; END IF;
END $$;

SELECT 'calib_run'         AS "table", count(*) AS "rows" FROM madi_results.calib_run r JOIN e2e_job USING (job_id)
UNION ALL SELECT 'calib_fit',         count(*) FROM madi_results.calib_fit         WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_param',       count(*) FROM madi_results.calib_param       WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_gate',        count(*) FROM madi_results.calib_gate        WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_grid',        count(*) FROM madi_results.calib_grid        WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_diagnostics', count(*) FROM madi_results.calib_diagnostics WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_samples',     count(*) FROM madi_results.calib_samples     WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_standards',   count(*) FROM madi_results.calib_standards   WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_blanks',      count(*) FROM madi_results.calib_blanks      WHERE curve_id IN (SELECT curve_id FROM e2e_curves)
UNION ALL SELECT 'calib_controls',    count(*) FROM madi_results.calib_controls    WHERE curve_id IN (SELECT curve_id FROM e2e_curves);

SELECT f.curve_id, f.model_name AS best_model,
       round(avg(s.recovery_pct)::numeric, 1) AS mean_recovery_pct,
       count(s.predicted_log10_concentration) AS standards_estimated
  FROM madi_results.calib_fit f
  JOIN madi_results.calib_standards s ON s.curve_id = f.curve_id AND s.method = f.method
 WHERE f.curve_id IN (SELECT curve_id FROM e2e_curves) AND f.is_best
 GROUP BY 1, 2 ORDER BY 1;

SELECT 'e2e check passed';
