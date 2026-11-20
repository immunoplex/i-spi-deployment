-- =============================================================================
-- tests/e2e/seed.sql -- a tiny synthetic study for the end-to-end fit test.
--
-- One project, study E2E / experiment IGG, antigen AgX, two plates. Each plate:
--   * standards (source STD1): 8 three-fold dilutions (2 ... 4374) in duplicate,
--     responses from a 4-parameter logistic in concentration
--     (top 20000, bottom 30, EC50 100, slope 1), with the standard's stock
--     concentration 10000 (the seeded system default standard_curve_concentration);
--   * 2 blank wells;
--   * 2 controls (QC1 low, QC2 high) in duplicate;
--   * 4 test samples at dilution 100.
-- Values are deterministic (no random noise), with +/-3 % duplicate spread.
-- One curve_lookup row per plate; the multiplate group comes from the trigger.
-- Run as the database owner on a database loaded from db/.
-- =============================================================================
\set ON_ERROR_STOP 1
BEGIN;

INSERT INTO madi_lumi_users.projects (project_name) VALUES ('e2e-test');

CREATE TEMP TABLE e2e_plate AS
SELECT (SELECT max(project_id) FROM madi_lumi_users.projects) AS project_id,
       p AS n, 'e2e_p' || p AS plateid, 'plate_' || p AS plate,
       'e2e/plate_' || p || '.csv' AS plate_id
  FROM generate_series(1, 2) AS p;

INSERT INTO madi_results.curve_lookup
       (project_id, study_accession, experiment_accession, plateid, plate,
        nominal_sample_dilution, source, antigen)
SELECT project_id, 'E2E', 'IGG', plateid, plate, '100', 'STD1', 'AgX' FROM e2e_plate;

INSERT INTO madi_results.xmap_header
       (study_accession, experiment_accession, plate_id, project_id, plateid, plate,
        nominal_sample_dilution, assay_response_variable, assay_independent_variable)
SELECT 'E2E', 'IGG', plate_id, project_id, plateid, plate, '100', 'mfi', 'concentration'
  FROM e2e_plate;

-- standards: dilution d = 2 * 3^(k-1), concentration 10000 / d
INSERT INTO madi_results.xmap_standard
       (study_accession, experiment_accession, plate_id, well, stype, sampleid, source,
        dilution, antigen, antibody_mfi, antibody_n, project_id, plateid,
        nominal_sample_dilution, plate)
SELECT 'E2E', 'IGG', p.plate_id, chr(64 + k) || r, 'S', 'S' || k, 'STD1',
       2 * 3 ^ (k - 1), 'AgX',
       round(((30 + (20000 - 30) / (1 + (100 / (10000.0 / (2 * 3 ^ (k - 1)))) ^ 1))
              * CASE r WHEN 1 THEN 0.97 ELSE 1.03 END * (1 + 0.01 * p.n))::numeric, 1),
       100, p.project_id, p.plateid, '100', p.plate
  FROM e2e_plate p, generate_series(1, 8) AS k, generate_series(1, 2) AS r;

INSERT INTO madi_results.xmap_buffer
       (study_accession, experiment_accession, plate_id, well, stype, antigen,
        antibody_mfi, antibody_n, project_id, plateid, nominal_sample_dilution, plate)
SELECT 'E2E', 'IGG', p.plate_id, 'H' || r, 'B', 'AgX', 25 + r, 100,
       p.project_id, p.plateid, '100', p.plate
  FROM e2e_plate p, generate_series(1, 2) AS r;

-- controls: a low and a high control (QC1, QC2) in duplicate at dilution 100;
-- the worker estimates them after the fit into calib_controls (schema 0.7.0)
INSERT INTO madi_results.xmap_control
       (study_accession, experiment_accession, plate_id, well, stype, sampleid, source,
        dilution, antigen, antibody_mfi, antibody_n, project_id, plateid,
        nominal_sample_dilution, plate)
SELECT 'E2E', 'IGG', p.plate_id, 'F' || (2 * (q - 1) + r), 'C', 'QC' || q, 'QC' || q,
       100, 'AgX', (ARRAY[1200, 9000])[q] * CASE r WHEN 1 THEN 0.98 ELSE 1.02 END, 100,
       p.project_id, p.plateid, '100', p.plate
  FROM e2e_plate p, generate_series(1, 2) AS q, generate_series(1, 2) AS r;

-- samples: responses spread over the curve's range
INSERT INTO madi_results.xmap_sample
       (study_accession, experiment_accession, plate_id, timeperiod, patientid, well,
        stype, sampleid, agroup, dilution, antigen, antibody_mfi, antibody_n,
        project_id, plateid, nominal_sample_dilution, plate)
SELECT 'E2E', 'IGG', p.plate_id, 'T1', 'P' || s, 'G' || s, 'X', 'SMP' || s, 'A',
       100, 'AgX', (ARRAY[600, 2500, 8000, 15000])[s] * (1 + 0.01 * p.n), 100,
       p.project_id, p.plateid, '100', p.plate
  FROM e2e_plate p, generate_series(1, 4) AS s;

COMMIT;

SELECT 'seeded ' || count(*) || ' curves' FROM madi_results.curve_lookup WHERE study_accession = 'E2E';
