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
ROLLBACK;
