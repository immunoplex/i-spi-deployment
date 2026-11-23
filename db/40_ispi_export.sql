-- =============================================================================
-- 40_ispi_export.sql -- ispi_export: the read-only interface other systems use
-- to read I-SPI results (first consumer: the MADI Data Portal's I-SPI migration)
--
-- Why a separate schema: consumers read a small, stable set of views instead of
-- I-SPI's working tables, so I-SPI can change its tables without breaking them,
-- and a consumer's database role can be limited to this one schema.
--
-- Contents
--   model_qc        one row per curve and fit method (frequentist / bayesian):
--                   the best model's parameters, limits and fit statistics.
--                   Columns 1-39 keep the names and meaning of the retired
--                   madi_results.get_model_qc_data(); new columns follow.
--   standard_curve  the subset of model_qc the portal stores as standard curves
--                   (replaces reads of the retired best_glance_all).
--   sample_qc       one row per sample well, curve and fit method: the sample's
--                   estimated concentration with its raw well data. Columns 1-20
--                   keep the names of the retired get_sample_qc_data().
--   xmap_header, xmap_sample, xmap_control, xmap_buffer, xmap_standard,
--   xmap_planned_visit (+ xmap_subjects, xmap_sample_timing where present):
--                   the raw tables, unchanged.
--   check_access_key(project_id, access_key) -> boolean: validates a project
--                   access key without exposing the key table.
--   model_y(), model_dydx(): the curve models, used by model_qc (with the
--                   overflow-safe helpers safe_exp(), safe_pow()).
--
-- Scales: lloq, uloq, llod, ulod, mindc, maxdc, minrdl, maxrdl, inflect_x are on
-- the fitted x-scale, log10(concentration), as in the retired tables; the
-- *_conc columns are concentrations. lloq_y, uloq_y, inflect_y are on the
-- fitted response scale (log10 when is_log_response).
-- Derived values: aic is the selection score where the fit was selected by AIC
-- (frequentist); loglik = (2k - aic)/2 and bic = k ln(nobs) - 2 loglik with
-- k = n_params; mse = sigma_resid^2; nobs = standards included in the fit.
--
-- Loaded after 00-30 on a new database; on an existing database run this file
-- alone (it only creates the schema, views and functions, plus planner
-- statistics on two madi_results tables, and is idempotent).
-- Grants are given to ispi_export_reader when that role exists.
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS ispi_export;
COMMENT ON SCHEMA ispi_export IS 'Read-only interface to I-SPI results for other systems (views only). See 40_ispi_export.sql.';

-- ── Curve models (curveRcore formulas.R / derivatives.R) ─────────────────────
-- x on the fitted scale (log10 concentration). Real fits can push the
-- exponentials past what double precision holds, so every exp() and power() goes
-- through safe_exp() / safe_pow(), which return 0 or a large finite value at the
-- limits instead of raising an overflow/underflow error, and the slopes are
-- written in forms whose intermediate values stay finite.
CREATE OR REPLACE FUNCTION ispi_export.safe_exp(x double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN x IS NULL THEN NULL WHEN x < -700 THEN 0 ELSE exp(least(700, x)) END
$$;
CREATE OR REPLACE FUNCTION ispi_export.safe_pow(base double precision, e double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN base IS NULL OR e IS NULL THEN NULL
              WHEN base > 0 THEN ispi_export.safe_exp(e * ln(base))
              WHEN base = 0 AND e > 0 THEN 0 END
$$;

CREATE OR REPLACE FUNCTION ispi_export.model_y(
  p_model text, x double precision, a double precision, b double precision,
  c double precision, d double precision, g double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE p_model
    WHEN 'logistic4'    THEN a + (d - a) / (1 + ispi_export.safe_exp(-(x - c) / b))
    WHEN 'logistic5'    THEN a + (d - a) * ispi_export.safe_pow(1 + ispi_export.safe_exp(-(x - c) / b), -g)
    WHEN 'loglogistic4' THEN CASE WHEN x > 0 THEN a + (d - a) / (1 + ispi_export.safe_pow(c / x, b)) END
    WHEN 'loglogistic5' THEN a + (d - a) * ispi_export.safe_pow(1 + g * ispi_export.safe_exp(-b * (x - c)), -1 / g)
    WHEN 'gompertz4'    THEN a + (d - a) * ispi_export.safe_exp(-ispi_export.safe_exp(-b * (x - c)))
  END
$$;
COMMENT ON FUNCTION ispi_export.model_y IS 'Response of a fitted curveRcore model at x (log10 concentration).';

-- Slopes, rewritten from curveRcore derivatives.R with s = 1/(1 + u):
--   logistic4     (d-a)/b * s(1-s)                      u = exp(-(x-c)/b)
--   logistic5     g(d-a)/b * (1-s) * s^g
--   loglogistic4  b(d-a)/x * t(1-t)                     t = 1/(1 + (c/x)^b)
--   loglogistic5  b(d-a) * exp(-b(x-c) - (1/g + 1) ln(1 + g exp(-b(x-c))))
--   gompertz4     b(d-a) * exp(-b(x-c) - exp(-b(x-c)))
CREATE OR REPLACE FUNCTION ispi_export.model_dydx(
  p_model text, x double precision, a double precision, b double precision,
  c double precision, d double precision, g double precision)
RETURNS double precision LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE p_model
    WHEN 'logistic4'    THEN (d - a) / b * s * (1 - s)
    WHEN 'logistic5'    THEN g * (d - a) / b * (1 - s) * ispi_export.safe_pow(s, g)
    WHEN 'loglogistic4' THEN CASE WHEN x > 0 THEN b * (d - a) / x * t * (1 - t) END
    WHEN 'loglogistic5' THEN CASE WHEN 1 + g * ispi_export.safe_exp(-b * (x - c)) > 0 THEN
                               b * (d - a) * ispi_export.safe_exp(-b * (x - c)
                                 - (1 / g + 1) * ln(1 + g * ispi_export.safe_exp(-b * (x - c)))) END
    WHEN 'gompertz4'    THEN b * (d - a) * ispi_export.safe_exp(-b * (x - c) - ispi_export.safe_exp(-b * (x - c)))
  END
  FROM (SELECT 1 / (1 + ispi_export.safe_exp(-(x - c) / b)) AS s,
               CASE WHEN x > 0 THEN 1 / (1 + ispi_export.safe_pow(c / x, b)) END AS t) k
$$;
COMMENT ON FUNCTION ispi_export.model_dydx IS 'Slope dy/dx of a fitted curveRcore model at x (log10 concentration).';

-- ── the fit settings model_qc reports, without access to the settings tables ─
-- resolve_settings() runs with its caller's rights and reads calib_settings, so
-- a view that calls it directly fails for consumer roles. This wrapper runs with
-- its owner's rights and returns only the four settings model_qc shows.
CREATE OR REPLACE FUNCTION ispi_export.curve_settings(p_project integer, p_study text, p_experiment text,
                                                      p_feature text, p_antigen text)
RETURNS TABLE (is_log_response boolean, is_log_independent boolean, blank_option text, apply_prozone boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
  SELECT max(rs.value_text) FILTER (WHERE rs.param_name = 'is_log_response')::boolean,
         max(rs.value_text) FILTER (WHERE rs.param_name = 'is_log_independent')::boolean,
         max(rs.value_text) FILTER (WHERE rs.param_name = 'blank_option'),
         max(rs.value_text) FILTER (WHERE rs.param_name = 'apply_prozone')::boolean
  FROM madi_results.resolve_settings(p_project, p_study::varchar, p_experiment::varchar,
                                     p_feature::varchar, p_antigen::varchar) rs
$$;
COMMENT ON FUNCTION ispi_export.curve_settings IS 'Fit settings shown in model_qc (log response, log x, blank option, prozone) for one curve. Runs with its owner''s rights so consumers need no access to calib_settings.';
REVOKE ALL ON FUNCTION ispi_export.curve_settings(integer, text, text, text, text) FROM PUBLIC;

-- ── model_qc ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW ispi_export.model_qc AS
WITH par AS (
  SELECT curve_id, method, model_name,
         max(estimate) FILTER (WHERE term = 'a') AS a, max(estimate) FILTER (WHERE term = 'b') AS b,
         max(estimate) FILTER (WHERE term = 'c') AS c, max(estimate) FILTER (WHERE term = 'd') AS d,
         max(estimate) FILTER (WHERE term = 'g') AS g,
         max(estimate) FILTER (WHERE term = 'sigma_resid') AS sigma_resid
  FROM madi_results.calib_param GROUP BY curve_id, method, model_name
), nob AS (
  SELECT curve_id, method, count(*) FILTER (WHERE included) AS nobs
  FROM madi_results.calib_standards GROUP BY curve_id, method
), base AS (
  SELECT f.curve_id, f.method, f.model_name, f.n_params, f.score_type, f.criterion, f.selection_score,
         f.converged, f.job_id, f.created_at,
         cl.project_id, cl.study_accession, cl.experiment_accession, cl.plateid, cl.plate,
         cl.nominal_sample_dilution, cl.antigen, cl.feature, cl.source, cl.wavelength,
         p.a, p.b, p.c, p.d, p.g, p.sigma_resid, nob.nobs, d.*,
         r.params AS run_params, r.manifest AS run_manifest,
         s.is_log_response AS set_is_log_response, s.is_log_independent AS set_is_log_x,
         s.blank_option AS set_blank_option, s.apply_prozone AS set_apply_prozone
  FROM madi_results.calib_fit f
  JOIN madi_results.curve_lookup cl ON cl.curve_id = f.curve_id
  LEFT JOIN par p ON p.curve_id = f.curve_id AND p.method = f.method AND p.model_name = f.model_name
  LEFT JOIN nob ON nob.curve_id = f.curve_id AND nob.method = f.method
  LEFT JOIN LATERAL (
    SELECT dd.lloq_log10, dd.uloq_log10, dd.lloq_conc, dd.uloq_conc,
           dd.lower_lod_log10_conc, dd.upper_lod_log10_conc, dd.lower_lod_conc, dd.upper_lod_conc,
           dd.mdc_lower_log10, dd.mdc_upper_log10, dd.rdl_lower_log10, dd.rdl_upper_log10,
           dd.inflect_x, dd.inflect_y
    FROM madi_results.calib_diagnostics dd
    WHERE dd.curve_id = f.curve_id AND dd.method = f.method AND dd.model_name = f.model_name
    LIMIT 1) d ON true
  LEFT JOIN madi_results.calib_run r ON r.job_id = f.job_id
  LEFT JOIN LATERAL ispi_export.curve_settings(cl.project_id, cl.study_accession, cl.experiment_accession,
                                               coalesce(cl.feature, '__none__'), coalesce(cl.antigen, '__none__')) s ON true
  WHERE f.is_best
)
SELECT
  -- 1-39: the columns of the retired get_model_qc_data(), same meaning
  (b.curve_id * 2 + (b.method = 'bayesian')::int)::bigint               AS model_qc_id,
  b.project_id                                                           AS workspace_id,
  b.study_accession                                                      AS study_name,
  b.experiment_accession                                                 AS experiment_name,
  b.plate                                                                AS plate_number,
  b.nominal_sample_dilution,
  b.source                                                               AS source_standard,
  b.experiment_accession                                                 AS analyte_name,  -- as in the retired function
  b.antigen                                                              AS reagent_name,
  CASE b.model_name WHEN 'logistic4' THEN 'logistic 4 parameter' WHEN 'logistic5' THEN 'logistic 5 parameter'
                    WHEN 'loglogistic4' THEN 'log-logistic 4 parameter' WHEN 'loglogistic5' THEN 'log-logistic 5 parameter'
                    WHEN 'gompertz4' THEN 'gompertz 4 parameter' ELSE b.model_name END  AS formula_name,
  CASE b.model_name WHEN 'logistic4'    THEN 'y ~ a + (d - a) / (1 + exp(-((x - c) / b)))'
                    WHEN 'logistic5'    THEN 'y ~ a + (d - a) / (1 + exp(-((x - c) / b)))^g'
                    WHEN 'loglogistic4' THEN 'y ~ a + (d - a) / (1 + (c / x)^b)'
                    WHEN 'loglogistic5' THEN 'y ~ a + (d - a) * (1 + g * exp(-b * (x - c)))^(-1/g)'
                    WHEN 'gompertz4'    THEN 'y ~ a + (d - a) * exp(-exp(-b * (x - c)))' END  AS formula,
  b.a, b.b, b.c, b.d, b.g,
  b.set_blank_option                                                     AS bkg_method,
  coalesce((b.run_params ->> 'is_log_response')::boolean, b.set_is_log_response)      AS is_log_response,
  coalesce((b.run_params ->> 'is_log_independent')::boolean, b.set_is_log_x)          AS is_log_x,
  b.set_apply_prozone                                                    AS apply_prozone,
  (b.nobs - b.n_params)::numeric                                         AS dfresidual,
  b.nobs::numeric                                                        AS nobs,
  b.lloq_log10                                                           AS lloq,
  b.uloq_log10                                                           AS uloq,
  -- clamped: at the asymptote rounding can leave y a few 1e-15 outside [a, d]
  greatest(least(b.a, b.d), least(greatest(b.a, b.d),
    ispi_export.model_y(b.model_name, b.lloq_log10, b.a, b.b, b.c, b.d, b.g)::numeric)) AS lloq_y,
  -- clamped: at the asymptote rounding can leave y a few 1e-15 outside [a, d]
  greatest(least(b.a, b.d), least(greatest(b.a, b.d),
    ispi_export.model_y(b.model_name, b.uloq_log10, b.a, b.b, b.c, b.d, b.g)::numeric)) AS uloq_y,
  b.lower_lod_log10_conc                                                 AS llod,
  b.mdc_lower_log10                                                      AS mindc,
  b.rdl_lower_log10                                                      AS minrdl,
  b.upper_lod_log10_conc                                                 AS ulod,
  b.mdc_upper_log10                                                      AS maxdc,
  b.rdl_upper_log10                                                      AS maxrdl,
  b.inflect_x, b.inflect_y,
  ispi_export.model_dydx(b.model_name, b.inflect_x, b.a, b.b, b.c, b.d, b.g)::numeric AS dydx_inflect,
  CASE WHEN b.score_type = 'aic' THEN b.selection_score END             AS aic,
  CASE WHEN b.score_type = 'aic' AND b.nobs > 0
       THEN b.n_params * ln(b.nobs::numeric) - (2 * b.n_params - b.selection_score) END AS bic,
  CASE WHEN b.score_type = 'aic' THEN (2 * b.n_params - b.selection_score) / 2 END   AS loglik,
  power(b.sigma_resid, 2)::double precision                              AS mse,
  -- 40+: new
  b.curve_id, b.method, b.model_name, b.project_id, b.study_accession, b.experiment_accession,
  b.plateid, b.plate, b.antigen, b.feature, b.source, b.wavelength,
  b.lloq_conc, b.uloq_conc, b.lower_lod_conc AS llod_conc, b.upper_lod_conc AS ulod_conc,
  b.sigma_resid, b.n_params, b.converged, b.criterion AS selection_criterion, b.score_type, b.selection_score,
  b.job_id AS fit_job_id, b.created_at AS fitted_at,
  b.run_manifest ->> 'version' AS compute_version
FROM base b;
COMMENT ON VIEW ispi_export.model_qc IS 'Best fit per curve and method. Columns 1-39 match the retired get_model_qc_data(); see 40_ispi_export.sql for scales and derived values.';

-- ── standard_curve (replaces reads of best_glance_all) ──────────────────────
CREATE OR REPLACE VIEW ispi_export.standard_curve AS
SELECT m.project_id, m.study_accession, m.experiment_accession, m.plateid, m.plate,
       m.nominal_sample_dilution, m.antigen, m.feature, m.source, m.wavelength,
       m.method, m.model_name, m.formula_name, m.formula, m.a, m.b, m.c, m.d, m.g,
       m.lloq, m.uloq, m.llod, m.ulod, m.lloq_conc, m.uloq_conc, m.llod_conc, m.ulod_conc,
       m.inflect_x, m.inflect_y, m.is_log_response, m.is_log_x, m.curve_id, m.fit_job_id, m.fitted_at
FROM ispi_export.model_qc m;
COMMENT ON VIEW ispi_export.standard_curve IS 'Standard-curve parameters per curve and method (replaces best_glance_all for consumers).';

-- ── sample_qc ────────────────────────────────────────────────────────────────
-- Wells are matched to curves exactly as madi_results.sample_for_fit matches
-- them for fitting, then to the curve's sample estimate on sample id, patient,
-- time period and dilution (calib_samples stores missing values as '__none__'
-- and dilution as text, e.g. '1e+05', hence the conversions).
CREATE OR REPLACE VIEW ispi_export.sample_qc AS
SELECT
  -- 1-20: the columns of the retired get_sample_qc_data(), same meaning
  -- stable id for (well, curve, method): a well can belong to several curves
  hashtextextended(concat_ws('|', s.xmap_sample_id, cl.curve_id, cs.method), 0) AS sample_qc_id,
  s.project_id                       AS workspace_id,
  s.study_accession                  AS study_name,
  s.experiment_accession             AS experiment_name,
  s.plate                            AS plate_number,
  s.well                             AS plate_well,
  s.nominal_sample_dilution,
  s.feature                          AS analyte_name,
  s.antigen                          AS reagent_name,
  s.timeperiod,
  s.patientid                        AS subject_id,
  s.dilution                         AS sample_dilution,
  s.pctaggbeads,
  s.samplingerrors,
  s.antibody_n                       AS bead_count,
  s.antibody_mfi                     AS mfi,
  cs.final_concentration::double precision AS predicted_concentration,
  cs.se_concentration,
  CASE WHEN cs.censor_class = 'quantified'                                              THEN 'Acceptable'
       WHEN cs.censor_class IN ('below_lloq', 'lod_to_lloq', 'below_lod', 'no_response') THEN 'Too Diluted'
       WHEN cs.censor_class IN ('above_uloq', 'saturated')                              THEN 'Too Concentrated'
       WHEN lx.x IS NOT NULL AND lim.lloq_log10 IS NOT NULL AND lx.x < lim.lloq_log10      THEN 'Too Diluted'
       WHEN lx.x IS NOT NULL AND lim.uloq_log10 IS NOT NULL AND lx.x > lim.uloq_log10      THEN 'Too Concentrated'
       WHEN lx.x IS NOT NULL AND lim.lloq_log10 IS NOT NULL AND lim.uloq_log10 IS NOT NULL THEN 'Acceptable'
       WHEN cs.pcov_gate_class = 'inDynamicRange' THEN 'Acceptable'
       WHEN cs.pcov_gate_class = 'belowLLOQ'      THEN 'Too Diluted'
       WHEN cs.pcov_gate_class = 'aboveULOQ'      THEN 'Too Concentrated' END            AS gate_class_loq,
  CASE WHEN cs.censor_class IN ('below_lod', 'no_response')                              THEN 'Too Diluted'
       WHEN cs.censor_class = 'saturated'                                                THEN 'Too Concentrated'
       WHEN cs.censor_class IS NOT NULL                                                  THEN 'Acceptable'
       WHEN lx.x IS NOT NULL AND lim.llod IS NOT NULL AND lx.x < lim.llod                  THEN 'Too Diluted'
       WHEN lx.x IS NOT NULL AND lim.ulod IS NOT NULL AND lx.x > lim.ulod                  THEN 'Too Concentrated'
       WHEN lx.x IS NOT NULL AND lim.llod IS NOT NULL AND lim.ulod IS NOT NULL            THEN 'Acceptable' END AS gate_class_lod,
  -- 21+: new
  cl.curve_id, cs.method, s.xmap_sample_id, s.sampleid, s.patientid, s.agroup, s.plateid,
  s.antigen, s.feature, cl.source, cl.wavelength,
  cs.predicted_concentration AS raw_predicted_concentration, cs.predicted_log10_concentration,
  cs.pcov, cs.pcov_gate_class, cs.censor_class, cs.censor_type,
  cs.conc_q_lo, cs.conc_q_med, cs.conc_q_hi, cs.p_below_lloq, cs.p_above_uloq,
  CASE WHEN cs.censor_class IS NOT NULL THEN 'censor_class'
       WHEN lx.x IS NOT NULL AND (lim.lloq_log10 IS NOT NULL OR lim.llod IS NOT NULL) THEN 'limits'
       WHEN cs.pcov_gate_class IS NOT NULL THEN 'pcov_gate_class' END          AS gate_class_basis,
  cs.job_id AS fit_job_id, cs.created_at AS fitted_at
FROM madi_results.xmap_sample s
JOIN madi_results.curve_lookup cl
  ON cl.project_id = s.project_id AND cl.study_accession = s.study_accession
 AND cl.experiment_accession = s.experiment_accession AND cl.plateid = s.plateid AND cl.plate = s.plate
 AND cl.nominal_sample_dilution = s.nominal_sample_dilution
 AND cl.wavelength = coalesce(s.wavelength, '__none__') AND cl.antigen = coalesce(s.antigen, '__none__')
 AND cl.feature = coalesce(s.feature, '__none__') AND NOT cl.masked
JOIN madi_results.calib_samples cs
  ON cs.curve_id = cl.curve_id
 AND cs.sampleid = coalesce(s.sampleid, '__none__') AND cs.patientid = coalesce(s.patientid, '__none__')
 AND cs.timeperiod = coalesce(s.timeperiod, '__none__')
 AND cs.dilution ~ '^[-+0-9.eE]+$' AND cs.dilution::numeric = s.dilution
-- the sample's estimate on the log10 scale, for the limit comparison
-- (predicted_* is on the curve's scale; final_concentration is dilution-adjusted
-- and must not be compared with the curve limits)
CROSS JOIN LATERAL (SELECT coalesce(cs.predicted_log10_concentration,
                                   CASE WHEN cs.predicted_concentration > 0 THEN log(cs.predicted_concentration) END)::double precision AS x) lx
-- the limits of the best model this sample was estimated with
LEFT JOIN LATERAL (
  SELECT dd.lloq_log10, dd.uloq_log10, dd.lower_lod_log10_conc AS llod, dd.upper_lod_log10_conc AS ulod
  FROM madi_results.calib_fit f
  JOIN madi_results.calib_diagnostics dd ON dd.curve_id = f.curve_id AND dd.method = f.method AND dd.model_name = f.model_name
  WHERE f.curve_id = cs.curve_id AND f.method = cs.method AND f.is_best
  LIMIT 1) lim ON true
WHERE NOT s.masked;
COMMENT ON VIEW ispi_export.sample_qc IS 'Sample estimates per well, curve and method. Columns 1-20 match the retired get_sample_qc_data(). Gate classes come from censor_class, else from the curve limits, else from pcov_gate_class (see gate_class_basis).';

-- ── raw tables, unchanged ────────────────────────────────────────────────────
CREATE OR REPLACE VIEW ispi_export.xmap_header        AS SELECT * FROM madi_results.xmap_header;
CREATE OR REPLACE VIEW ispi_export.xmap_sample        AS SELECT * FROM madi_results.xmap_sample;
CREATE OR REPLACE VIEW ispi_export.xmap_control       AS SELECT * FROM madi_results.xmap_control;
CREATE OR REPLACE VIEW ispi_export.xmap_buffer        AS SELECT * FROM madi_results.xmap_buffer;
CREATE OR REPLACE VIEW ispi_export.xmap_standard      AS SELECT * FROM madi_results.xmap_standard;
CREATE OR REPLACE VIEW ispi_export.xmap_planned_visit AS SELECT * FROM madi_results.xmap_planned_visit;
-- Subject / timing maps exist only in databases that carry the legacy tables.
DO $$ BEGIN
  IF to_regclass('madi_results.xmap_subjects') IS NOT NULL THEN
    EXECUTE 'CREATE OR REPLACE VIEW ispi_export.xmap_subjects AS SELECT * FROM madi_results.xmap_subjects';
  END IF;
  IF to_regclass('madi_results.xmap_sample_timing') IS NOT NULL THEN
    EXECUTE 'CREATE OR REPLACE VIEW ispi_export.xmap_sample_timing AS SELECT * FROM madi_results.xmap_sample_timing';
  END IF;
END $$;

-- ── access-key check (the key table itself stays private) ───────────────────
CREATE OR REPLACE FUNCTION ispi_export.check_access_key(p_project_id integer, p_access_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM madi_lumi_users.project_access_keys k
                 WHERE k.project_id = p_project_id AND k.access_key::text = lower(trim(p_access_key)))
$$;
COMMENT ON FUNCTION ispi_export.check_access_key IS 'True when the access key belongs to the project. Runs with its owner''s rights so callers need no access to the key table.';
REVOKE ALL ON FUNCTION ispi_export.check_access_key(integer, text) FROM PUBLIC;

-- ── planner statistics for the per-experiment filters ───────────────────────
-- Consumers filter by project, study and experiment. Those columns depend on
-- each other (an experiment belongs to one study and project), and without
-- these statistics the planner multiplies their selectivities, expects a few
-- rows, and matches wells to curves with a nested loop: 18-35 s instead of
-- about 1 s for a 94,000-well experiment (production, 2026-11-23).
CREATE STATISTICS IF NOT EXISTS madi_results.xmap_sample_experiment_stats (dependencies, ndistinct)
  ON project_id, study_accession, experiment_accession FROM madi_results.xmap_sample;
CREATE STATISTICS IF NOT EXISTS madi_results.curve_lookup_experiment_stats (dependencies, ndistinct)
  ON project_id, study_accession, experiment_accession FROM madi_results.curve_lookup;
ANALYZE madi_results.xmap_sample;
ANALYZE madi_results.curve_lookup;

-- ── grants for the consumer role, when it exists ─────────────────────────────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ispi_export_reader') THEN
    GRANT USAGE ON SCHEMA ispi_export TO ispi_export_reader;
    GRANT SELECT ON ALL TABLES IN SCHEMA ispi_export TO ispi_export_reader;
    GRANT EXECUTE ON FUNCTION ispi_export.check_access_key(integer, text),
                              ispi_export.curve_settings(integer, text, text, text, text),
                              ispi_export.model_y(text, double precision, double precision, double precision, double precision, double precision, double precision),
                              ispi_export.model_dydx(text, double precision, double precision, double precision, double precision, double precision, double precision),
                              ispi_export.safe_exp(double precision),
                              ispi_export.safe_pow(double precision, double precision)
      TO ispi_export_reader;
  END IF;
END $$;
