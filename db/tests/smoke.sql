-- Smoke checks after loading db/*.sql into an empty database. Each SELECT prints
-- "ok <check>" or raises. Run by tests/load_test.sh.
\set ON_ERROR_STOP 1
BEGIN;
-- a new project gets an access key (trigger after_project_insert)
INSERT INTO madi_lumi_users.projects (project_name) VALUES ('smoke');
SELECT 'ok access key' WHERE (SELECT count(*) FROM madi_lumi_users.project_access_keys) = 1;
DO $$ BEGIN IF (SELECT count(*) FROM madi_lumi_users.project_access_keys) <> 1
  THEN RAISE EXCEPTION 'no access key'; END IF; END $$;

-- a curve gets its multiplate_group_id from the trigger
INSERT INTO madi_results.curve_lookup (project_id, study_accession, experiment_accession,
       plateid, plate, nominal_sample_dilution, antigen)
VALUES (1, 'S1', 'E1', 'p1', 'plate_1', '100', 'IgG');
DO $$ BEGIN IF (SELECT count(*) FROM madi_results.curve_lookup WHERE multiplate_group_id IS NOT NULL) <> 1
  THEN RAISE EXCEPTION 'multiplate_group_id not set'; END IF; END $$;
SELECT 'ok multiplate group';

-- every view and function the app and worker call can be executed
SELECT 'ok views ' || (SELECT count(*) FROM madi_results.curve_lookup_unmasked)
       + (SELECT count(*) FROM madi_results.sample_for_fit) + (SELECT count(*) FROM madi_results.standard_for_fit)
       + (SELECT count(*) FROM madi_results.blank_for_fit) + (SELECT count(*) FROM madi_results.control_for_fit)
       + (SELECT count(*) FROM madi_results.calib_controls_qc);
DO $$ BEGIN IF (SELECT count(*) FROM madi_results.resolve_settings(1, 'S1', 'E1', '__none__', 'IgG')) < 20
  THEN RAISE EXCEPTION 'settings cascade has no system defaults'; END IF; END $$;
SELECT 'ok resolve_settings ' || count(*) FROM madi_results.resolve_settings(1, 'S1', 'E1', '__none__', 'IgG');
SELECT 'ok resolve_settings_batch ' || count(*) FROM madi_results.resolve_settings_batch(ARRAY(SELECT curve_id FROM madi_results.curve_lookup));
SELECT 'ok schema_version ' || string_agg(component || ' ' || version, ', ') FROM madi_results.schema_version;
-- ispi_export: every view runs, the curve model is right at its inflection
-- (logistic4: y(c) = (a + d)/2, slope (d - a)/(4b)), and an unknown key fails
SELECT 'ok ispi_export views ' || (SELECT count(*) FROM ispi_export.model_qc)
       + (SELECT count(*) FROM ispi_export.standard_curve) + (SELECT count(*) FROM ispi_export.sample_qc)
       + (SELECT count(*) FROM ispi_export.xmap_sample);
DO $$ BEGIN
  IF abs(ispi_export.model_y('logistic4', 1.5, 1, 0.8, 1.5, 4, NULL) - 2.5) > 1e-12
     OR abs(ispi_export.model_dydx('logistic4', 1.5, 1, 0.8, 1.5, 4, NULL) - 3.0 / 3.2) > 1e-12
     OR ispi_export.model_y('gompertz4', -500, 1, 50, 1.5, 4, NULL) IS DISTINCT FROM 1
  THEN RAISE EXCEPTION 'ispi_export curve functions are wrong'; END IF;
  IF ispi_export.check_access_key(-1, '00000000-0000-0000-0000-000000000000')
  THEN RAISE EXCEPTION 'check_access_key accepted an unknown key'; END IF;
END $$;
SELECT 'ok ispi_export functions';
-- a consumer role with only ispi_export grants can read model_qc's settings
-- (resolve_settings() needs calib_settings; curve_settings() runs as its owner)
CREATE ROLE smoke_reader NOLOGIN;
GRANT USAGE ON SCHEMA ispi_export TO smoke_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA ispi_export TO smoke_reader;
GRANT EXECUTE ON FUNCTION ispi_export.curve_settings(integer, text, text, text, text),
                          ispi_export.model_y(text, double precision, double precision, double precision, double precision, double precision, double precision),
                          ispi_export.model_dydx(text, double precision, double precision, double precision, double precision, double precision, double precision),
                          ispi_export.safe_exp(double precision),
                          ispi_export.safe_pow(double precision, double precision) TO smoke_reader;
SET LOCAL ROLE smoke_reader;
DO $$ BEGIN
  IF (SELECT blank_option FROM ispi_export.curve_settings(1, 'S1', 'E1', '__none__', 'IgG')) IS NULL
  THEN RAISE EXCEPTION 'curve_settings returned no blank_option for a consumer role'; END IF;
END $$;
SELECT 'ok ispi_export consumer role ' || count(*) FROM ispi_export.model_qc;
RESET ROLE;
ROLLBACK;
