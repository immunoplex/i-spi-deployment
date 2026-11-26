-- =============================================================================
-- 20_calib_schema.sql -- calib_* results schema (calib schema 0.7.1).
-- VERBATIM copy of curveRcore R/calib_schema.sql at tag v0.7.1 (955d753);
-- do not edit here. Update by copying the file from a newer curveRcore tag.
-- =============================================================================

-- ============================================================================
-- calib_schema.sql — canonical DDL for madi_results.calib_*
--
-- Existing tables: transcribed VERBATIM from the live DB (extract_calib_ddl.sql
-- output), reordered into FK-dependency order for fresh-apply safety.
-- New tables (schema expansion): calib_hyperparam, calib_draws, calib_fit_diag —
-- reconciled to the family's real conventions (method text; FK (curve_id,method,
-- model_name)->calib_fit ON DELETE CASCADE, exactly like calib_param/calib_loo;
-- NO method CHECK on children; job_id varchar(64) + created_at like calib_loo).
--
-- PREREQUISITE (external, not created here): madi_results.curve_lookup — the
-- injection/lookup table that calib_fit / calib_diagnostics / calib_grid /
-- calib_samples / calib_controls FK to; and madi_results.xmap_header (plate
-- acquisition date), read by the calib_controls_qc view.
--
-- Idempotent (IF NOT EXISTS). Safe to re-run against the live DB.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS madi_results;

-- Sequence backing calib_settings.calib_settings_id (authoritative definition
-- from the live DB). The CREATE goes here (the column DEFAULT needs it); the
-- ALTER ... OWNED BY is deferred to after calib_settings is created (it
-- references that column). OWNER TO is environment-specific — see the tail.
CREATE SEQUENCE IF NOT EXISTS madi_results.calib_settings_calib_settings_id_seq
    INCREMENT 1
    START 1
    MINVALUE 1
    MAXVALUE 9223372036854775807
    CACHE 1;


-- ============================================================================
-- Job + fit hub
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_run (
    job_id character varying(64) NOT NULL,
    method text NOT NULL,
    package text,
    version text,
    best_model text,
    params jsonb,
    status text,
    started_at timestamp with time zone DEFAULT now(),
    finished_at timestamp with time zone,
    CONSTRAINT calib_run_pkey PRIMARY KEY (job_id),
    CONSTRAINT calib_run_method_check CHECK ((method = ANY (ARRAY['frequentist'::text, 'bayesian'::text])))
);

-- 0.7.0: provenance of each job. The worker writes the composite release
-- manifest it ran under (its image version and commit, R, curveR package
-- versions, CmdStan, calib schema version, renv lock hash) as built by
-- curveRcore::release_manifest(). NULL for jobs run before 0.7.0.
ALTER TABLE madi_results.calib_run
    ADD COLUMN IF NOT EXISTS manifest jsonb;

CREATE TABLE IF NOT EXISTS madi_results.calib_fit (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    package text,
    version text,
    converged boolean,
    eligible boolean,
    is_best boolean NOT NULL DEFAULT false,
    is_fallback boolean,
    criterion text,
    score_type text,
    selection_score numeric,
    selection_weight numeric,
    dynamic_range_log10 numeric,
    n_params integer,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_fit_pkey PRIMARY KEY (curve_id, method, model_name),
    CONSTRAINT calib_fit_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE,
    CONSTRAINT calib_fit_method_check CHECK ((method = ANY (ARRAY['frequentist'::text, 'bayesian'::text]))),
    CONSTRAINT calib_fit_score_type_check CHECK ((score_type = ANY (ARRAY['aic'::text, 'loo_elpd'::text])))
);


-- ============================================================================
-- Children FK -> calib_fit(curve_id, method, model_name)
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_param (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    term text NOT NULL,
    estimate numeric,
    std_error numeric,
    q_lo numeric,
    q_med numeric,
    q_hi numeric,
    job_id text,
    CONSTRAINT calib_param_pkey PRIMARY KEY (curve_id, method, model_name, term),
    CONSTRAINT calib_param_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS madi_results.calib_loo (
    curve_id bigint NOT NULL,
    method text NOT NULL DEFAULT 'bayesian'::text,
    model_name text NOT NULL,
    elpd_loo numeric,
    se_elpd_loo numeric,
    p_loo numeric,
    looic numeric,
    elpd_diff numeric,
    se_diff numeric,
    pareto_k_good integer,
    pareto_k_ok integer,
    pareto_k_bad integer,
    pareto_k_vbad integer,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_loo_pkey PRIMARY KEY (curve_id, method, model_name),
    CONSTRAINT calib_loo_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS madi_results.calib_gate (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    gate text NOT NULL,
    passed boolean,
    detail text,
    job_id text,
    CONSTRAINT calib_gate_pkey PRIMARY KEY (curve_id, method, model_name, gate),
    CONSTRAINT calib_gate_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);

-- ---- NEW: calib_hyperparam (population/noise params; always written) --------
-- Sibling of calib_param (per curve/method/model/term). Bayesian-only content
-- (mu_*, sigma_*, sigma_obs, nu), stored per-curve (duplicated across the group).
CREATE TABLE IF NOT EXISTS madi_results.calib_hyperparam (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    term text NOT NULL,
    param_scope text,
    estimate numeric,
    std_error numeric,
    q_lo numeric,
    q_med numeric,
    q_hi numeric,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_hyperparam_pkey PRIMARY KEY (curve_id, method, model_name, term),
    CONSTRAINT calib_hyperparam_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);

-- ---- NEW: calib_draws (posterior/sampling draws; gated by persist_draws) ----
CREATE TABLE IF NOT EXISTS madi_results.calib_draws (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    term text NOT NULL,
    param_scope text NOT NULL CHECK (param_scope IN ('curve', 'population')),
    sample_kind text CHECK (sample_kind IN ('posterior', 'mvn', 'fixed')),
    draws double precision[] NOT NULL,
    n_draws integer NOT NULL,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_draws_pkey PRIMARY KEY (curve_id, method, model_name, term, param_scope),
    CONSTRAINT calib_draws_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);

-- ---- NEW: calib_fit_diag (per-fit sampler/optimizer diagnostics; always) ----
-- Sibling of calib_loo (per curve/method/model). Distinct from calib_diagnostics
-- (the detection-limit/LOQ table). Bayesian + frequentist column banks coexist.
CREATE TABLE IF NOT EXISTS madi_results.calib_fit_diag (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text NOT NULL,
    fit_seconds numeric,
    n_iterations integer,
    converged boolean,
    fit_seed bigint,
    rhat_max numeric,
    ess_bulk_min numeric,
    ess_tail_min numeric,
    n_divergent integer,
    pct_divergent numeric,
    max_treedepth_hit integer,
    ebfmi_min numeric,
    hessian_condition_number numeric,
    gradient_norm numeric,
    optimizer_code integer,
    rel_tol_achieved numeric,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_fit_diag_pkey PRIMARY KEY (curve_id, method, model_name),
    CONSTRAINT calib_fit_diag_curve_id_method_model_name_fkey FOREIGN KEY (curve_id, method, model_name) REFERENCES madi_results.calib_fit(curve_id, method, model_name) ON DELETE CASCADE
);


-- ============================================================================
-- Children FK -> curve_lookup(curve_id)  (per-curve, model-agnostic)
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_diagnostics (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    model_name text,
    lloq_log10 numeric,
    uloq_log10 numeric,
    lloq_conc numeric,
    uloq_conc numeric,
    shape_lloq_log10 numeric,
    shape_uloq_log10 numeric,
    shape_lloq_conc numeric,
    shape_uloq_conc numeric,
    inflect_x numeric,
    inflect_y numeric,
    inflect_x_lower numeric,
    inflect_x_upper numeric,
    lower_lod_response numeric,
    upper_lod_response numeric,
    lower_lod_log10_conc numeric,
    upper_lod_log10_conc numeric,
    lower_lod_conc numeric,
    upper_lod_conc numeric,
    mdc_lower_log10 numeric,
    mdc_upper_log10 numeric,
    mdc_lower_conc numeric,
    mdc_upper_conc numeric,
    rdl_lower_log10 numeric,
    rdl_upper_log10 numeric,
    rdl_lower_conc numeric,
    rdl_upper_conc numeric,
    pcov_threshold numeric,
    cv_x_max numeric,
    decision_cutoff double precision,
    n_interval_draws integer,
    alpha numeric,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_diagnostics_pkey PRIMARY KEY (curve_id, method),
    CONSTRAINT calib_diagnostics_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS madi_results.calib_grid (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    point_index integer NOT NULL,
    model_name text,
    log10_concentration numeric,
    concentration numeric,
    predicted_response numeric,
    ci_lower numeric,
    ci_upper numeric,
    predicted_concentration numeric,
    se_concentration numeric,
    pcov numeric,
    pcov_rmse numeric,
    pcov_pass boolean,
    d2y_dx2 numeric,
    noise_mode text,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_grid_pkey PRIMARY KEY (curve_id, method, point_index),
    CONSTRAINT calib_grid_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS madi_results.calib_samples (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    sampleid character varying(128) NOT NULL,
    patientid character varying(128) NOT NULL DEFAULT '__none__'::character varying,
    timeperiod character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    dilution character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    predicted_concentration numeric,
    final_concentration numeric,
    se_concentration numeric,
    pcov numeric,
    pcov_rmse numeric,
    pcov_pass boolean,
    predicted_log10_concentration numeric,
    pcov_gate_class text,
    agroup character varying(40),
    censor_class text CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod',
                                              'below_lloq','above_uloq','saturated','no_response')),
    censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    censor_lower double precision,
    censor_upper double precision,
    conc_q_lo double precision,
    conc_q_med double precision,
    conc_q_hi double precision,
    p_below_lloq double precision,
    p_above_uloq double precision,
    p_below_cutoff double precision,
    frac_draws_below_a double precision,
    frac_draws_above_d double precision,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_samples_pkey PRIMARY KEY (curve_id, method, sampleid, patientid, timeperiod, dilution),
    CONSTRAINT calib_samples_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);


-- ============================================================================
-- Precision weights (curveRweights) — per-sample weights + per-group fit
--
-- calib_weights / calib_weights_fit were created by i-spi-compute migration 004
-- and transcribed here VERBATIM from the live DB (14 and 18 columns, live order;
-- agroup is last on calib_weights because it was added after creation).
-- Keys are UNCHANGED by the 0.6.0 extension: calib_weights shares calib_samples'
-- sample hierarchy (curve_id, method, sampleid, patientid, timeperiod, dilution);
-- calib_weights_fit is one row per (multiplate_group_id, method). There is ONE
-- weight set per (sample, method); `model` records which model produced it.
-- See calib_weights_SPEC.md and weights_contract().
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_weights (
    curve_id bigint NOT NULL,
    method text NOT NULL,
    sampleid character varying(128) NOT NULL,
    patientid character varying(128) NOT NULL DEFAULT '__none__'::character varying,
    timeperiod character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    dilution character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    se double precision,
    pcov double precision,
    sigma double precision,
    w double precision,
    w_norm double precision,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    agroup character varying(40),
    CONSTRAINT calib_weights_pkey PRIMARY KEY (curve_id, method, sampleid, patientid, timeperiod, dilution),
    CONSTRAINT calib_weights_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_calib_weights_patient
    ON madi_results.calib_weights USING btree (curve_id, patientid);

CREATE TABLE IF NOT EXISTS madi_results.calib_weights_fit (
    multiplate_group_id uuid NOT NULL,
    method text NOT NULL,
    antigen character varying(64),
    feature character varying(15),
    design_cols text,
    scale_predictor text,
    phi double precision,
    phi_lo double precision,
    phi_hi double precision,
    beta1 double precision,
    beta1_lo double precision,
    beta1_hi double precision,
    interpretation text,
    n_fit integer,
    n_eff double precision,
    weight_ratio double precision,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_weights_fit_pkey PRIMARY KEY (multiplate_group_id, method)
);

-- 0.6.0 extension: record the model and the concepts the additive
-- measurement-error model adds. All new columns are nullable (NULL = not
-- applicable to the model that wrote the row) except `model`, which defaults to
-- the model every pre-0.6.0 row used. ADD COLUMN IF NOT EXISTS makes this safe to
-- re-run against the live DB; on a fresh DB it yields the same column order.
-- No CHECK on `model` (family convention); validated by weights_contract().
ALTER TABLE madi_results.calib_weights
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'multiplicative',
    ADD COLUMN IF NOT EXISTS weights_pkg_version character varying(32),
    ADD COLUMN IF NOT EXISTS v_meas double precision,
    ADD COLUMN IF NOT EXISTS tau2 double precision,
    ADD COLUMN IF NOT EXISTS reliability double precision,
    ADD COLUMN IF NOT EXISTS reliability_lo double precision,
    ADD COLUMN IF NOT EXISTS reliability_hi double precision,
    ADD COLUMN IF NOT EXISTS censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    ADD COLUMN IF NOT EXISTS bound double precision;

ALTER TABLE madi_results.calib_weights_fit
    ADD COLUMN IF NOT EXISTS model text NOT NULL DEFAULT 'multiplicative',
    ADD COLUMN IF NOT EXISTS weights_pkg_version character varying(32),
    ADD COLUMN IF NOT EXISTS tau double precision,
    ADD COLUMN IF NOT EXISTS tau_lo double precision,
    ADD COLUMN IF NOT EXISTS tau_hi double precision,
    ADD COLUMN IF NOT EXISTS kappa double precision,
    ADD COLUMN IF NOT EXISTS kappa_lo double precision,
    ADD COLUMN IF NOT EXISTS kappa_hi double precision,
    ADD COLUMN IF NOT EXISTS reliability double precision,
    ADD COLUMN IF NOT EXISTS reliability_lo double precision,
    ADD COLUMN IF NOT EXISTS reliability_hi double precision,
    ADD COLUMN IF NOT EXISTS fix_beta1 boolean,
    ADD COLUMN IF NOT EXISTS n_censored integer,
    ADD COLUMN IF NOT EXISTS identifiability text,
    ADD COLUMN IF NOT EXISTS fit_options text,
    ADD COLUMN IF NOT EXISTS rhat_max double precision,
    ADD COLUMN IF NOT EXISTS n_divergent integer,
    ADD COLUMN IF NOT EXISTS ess_min double precision,
    ADD COLUMN IF NOT EXISTS ident_sd_ratio double precision,
    ADD COLUMN IF NOT EXISTS resid_sd double precision,
    ADD COLUMN IF NOT EXISTS resid_sd_ratio double precision;


-- ============================================================================
-- Children with NO FK (input echoes; keyed by curve/method/well)
-- (from 0.7.0 this section also holds calib_controls, which has an FK to
-- curve_lookup, and control_reference; the header line above is kept verbatim
-- because i-spi-compute's e2e test locates sections by it)
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_standards (
    curve_id bigint NOT NULL,
    method character varying(20) NOT NULL,
    well character varying(16) NOT NULL,
    dilution numeric NOT NULL,
    concentration numeric,
    log10_concentration numeric,
    response_model numeric,
    assay_response_raw numeric,
    included boolean NOT NULL,
    exclusion_reason character varying(20) NOT NULL DEFAULT 'none'::character varying,
    job_id text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    mask_reason character varying,
    CONSTRAINT calib_standards_pkey PRIMARY KEY (curve_id, method, well, dilution)
);

-- 0.7.0 extension: modelled estimates for each calibrator, the same columns
-- calib_samples holds for test samples, plus recovery_pct (standards know their
-- nominal value; pcov_rmse here includes the bias against it). All nullable:
-- rows written before 0.7.0 keep NULL estimates until the curve is refitted.
-- See calib_points_SPEC.md and point_estimates_contract().
ALTER TABLE madi_results.calib_standards
    ADD COLUMN IF NOT EXISTS predicted_concentration numeric,
    ADD COLUMN IF NOT EXISTS predicted_log10_concentration numeric,
    ADD COLUMN IF NOT EXISTS final_concentration numeric,
    ADD COLUMN IF NOT EXISTS se_concentration numeric,
    ADD COLUMN IF NOT EXISTS pcov numeric,
    ADD COLUMN IF NOT EXISTS pcov_rmse numeric,
    ADD COLUMN IF NOT EXISTS pcov_pass boolean,
    ADD COLUMN IF NOT EXISTS pcov_gate_class text CHECK (pcov_gate_class IN ('belowLLOQ','inDynamicRange','aboveULOQ')),
    ADD COLUMN IF NOT EXISTS censor_class text CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod',
                                                                       'below_lloq','above_uloq','saturated','no_response')),
    ADD COLUMN IF NOT EXISTS censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    ADD COLUMN IF NOT EXISTS censor_lower double precision,
    ADD COLUMN IF NOT EXISTS censor_upper double precision,
    ADD COLUMN IF NOT EXISTS conc_q_lo double precision,
    ADD COLUMN IF NOT EXISTS conc_q_med double precision,
    ADD COLUMN IF NOT EXISTS conc_q_hi double precision,
    ADD COLUMN IF NOT EXISTS p_below_lloq double precision,
    ADD COLUMN IF NOT EXISTS p_above_uloq double precision,
    ADD COLUMN IF NOT EXISTS p_below_cutoff double precision,
    ADD COLUMN IF NOT EXISTS frac_draws_below_a double precision,
    ADD COLUMN IF NOT EXISTS frac_draws_above_d double precision,
    ADD COLUMN IF NOT EXISTS recovery_pct double precision;

-- 0.7.0: modelled estimates for control wells. One row per (curve, method,
-- well): a control is estimated through every curve it can be read on (same
-- matching as test samples), masked controls included (included = false).
-- concentration / log10_concentration are the expected values, NULL until a
-- reference-value table exists (calib_points_SPEC.md, "Later").
CREATE TABLE IF NOT EXISTS madi_results.calib_controls (
    curve_id bigint NOT NULL,
    method character varying(20) NOT NULL,
    well character varying(20) NOT NULL,
    sampleid character varying(128),
    source character varying(64),
    dilution numeric,
    included boolean NOT NULL,
    exclusion_reason character varying(20) NOT NULL DEFAULT 'none'::character varying,
    mask_reason character varying,
    concentration numeric,
    log10_concentration numeric,
    response_model numeric,
    assay_response_raw numeric,
    predicted_concentration numeric,
    predicted_log10_concentration numeric,
    final_concentration numeric,
    se_concentration numeric,
    pcov numeric,
    pcov_rmse numeric,
    pcov_pass boolean,
    pcov_gate_class text CHECK (pcov_gate_class IN ('belowLLOQ','inDynamicRange','aboveULOQ')),
    censor_class text CHECK (censor_class IN ('quantified','lod_to_lloq','below_lod',
                                              'below_lloq','above_uloq','saturated','no_response')),
    censor_type text CHECK (censor_type IN ('none','left','interval','right')),
    censor_lower double precision,
    censor_upper double precision,
    conc_q_lo double precision,
    conc_q_med double precision,
    conc_q_hi double precision,
    p_below_lloq double precision,
    p_above_uloq double precision,
    p_below_cutoff double precision,
    frac_draws_below_a double precision,
    frac_draws_above_d double precision,
    job_id character varying(64),
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT calib_controls_pkey PRIMARY KEY (curve_id, method, well),
    CONSTRAINT calib_controls_curve_id_fkey FOREIGN KEY (curve_id) REFERENCES madi_results.curve_lookup(curve_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_calib_controls_source
    ON madi_results.calib_controls USING btree (curve_id, source);


-- ============================================================================
-- Control reference values (0.7.0; owned by I-SPI, never read by the engines)
--
-- The expected concentration of a control, kept apart from the fitted rows so
-- that a value assigned or corrected later applies to every run, past runs
-- included, with its history: one row per value and validity period.
-- Concentrations are at stock (dilution 1), the scale of
-- calib_controls.final_concentration. '__none__' in study_accession or feature
-- means the value applies to the whole project / every feature.
-- calib_controls_qc joins each control estimate to the value in force on the
-- plate's acquisition date (most specific scope first).
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.control_reference (
    reference_id bigint GENERATED ALWAYS AS IDENTITY,
    project_id integer NOT NULL,
    study_accession character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    control_source character varying(64) NOT NULL,
    control_lot character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    antigen character varying(64) NOT NULL,
    feature character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    units text,
    expected_conc numeric,
    expected_sd numeric,
    lower_limit numeric,
    upper_limit numeric,
    basis text,
    valid_from date NOT NULL DEFAULT '-infinity'::date,
    valid_to date,
    assigned_by text,
    assigned_at timestamp with time zone NOT NULL DEFAULT now(),
    note text,
    CONSTRAINT control_reference_pkey PRIMARY KEY (reference_id),
    CONSTRAINT control_reference_scope_uniq UNIQUE (project_id, study_accession, control_source, control_lot, antigen, feature, valid_from),
    CONSTRAINT control_reference_basis_chk CHECK (basis IS NULL OR basis IN ('certificate','assigned','historical')),
    CONSTRAINT control_reference_period_chk CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT control_reference_limits_chk CHECK (lower_limit IS NULL OR upper_limit IS NULL OR lower_limit <= upper_limit),
    CONSTRAINT control_reference_sd_chk CHECK (expected_sd IS NULL OR expected_sd > 0)
);

-- Prerequisites (external, not created here): curve_lookup and xmap_header.
CREATE OR REPLACE VIEW madi_results.calib_controls_qc AS
SELECT cc.curve_id, cc.method, cc.well, cc.sampleid, cc.source, cc.dilution,
       cc.included, cc.exclusion_reason, cc.mask_reason,
       cc.final_concentration, cc.predicted_log10_concentration, cc.se_concentration,
       cc.pcov, cc.pcov_pass, cc.pcov_gate_class, cc.censor_class, cc.censor_type,
       cc.conc_q_lo, cc.conc_q_med, cc.conc_q_hi, cc.job_id,
       cl.project_id, cl.study_accession, cl.experiment_accession, cl.plateid, cl.plate,
       cl.antigen, cl.feature, cl.source AS standard_source, cl.wavelength,
       hd.run_date,
       r.reference_id, r.control_lot, r.units, r.expected_conc, r.expected_sd,
       r.lower_limit, r.upper_limit, r.basis,
       CASE WHEN r.expected_conc > 0 AND cc.final_concentration IS NOT NULL
            THEN 100 * cc.final_concentration / r.expected_conc END AS recovery_pct,
       CASE WHEN r.expected_sd > 0 AND cc.final_concentration IS NOT NULL
            THEN (cc.final_concentration - r.expected_conc) / r.expected_sd END AS z_score,
       CASE WHEN cc.final_concentration IS NULL
              OR (r.lower_limit IS NULL AND r.upper_limit IS NULL) THEN NULL
            ELSE cc.final_concentration >= COALESCE(r.lower_limit, cc.final_concentration)
             AND cc.final_concentration <= COALESCE(r.upper_limit, cc.final_concentration)
       END AS within_limits
FROM madi_results.calib_controls cc
JOIN madi_results.curve_lookup cl ON cl.curve_id = cc.curve_id
LEFT JOIN LATERAL (
    SELECT min(h.acquisition_date) AS run_date
    FROM madi_results.xmap_header h
    WHERE h.project_id = cl.project_id
      AND h.study_accession = cl.study_accession
      AND h.experiment_accession = cl.experiment_accession
      AND h.plateid = cl.plateid
) hd ON true
LEFT JOIN LATERAL (
    SELECT r0.*
    FROM madi_results.control_reference r0
    WHERE r0.project_id = cl.project_id
      AND r0.study_accession IN (cl.study_accession, '__none__')
      AND r0.control_source = cc.source
      AND r0.antigen = cl.antigen
      AND r0.feature IN (cl.feature, '__none__')
      AND (hd.run_date IS NULL
           OR (r0.valid_from <= hd.run_date::date
               AND (r0.valid_to IS NULL OR hd.run_date::date < r0.valid_to)))
    ORDER BY (r0.study_accession <> '__none__') DESC, (r0.feature <> '__none__') DESC,
             r0.valid_from DESC
    LIMIT 1
) r ON true;

CREATE TABLE IF NOT EXISTS madi_results.calib_blanks (
    curve_id bigint NOT NULL,
    method character varying(20) NOT NULL,
    well character varying(16) NOT NULL,
    response_model numeric,
    assay_response_raw numeric,
    included boolean NOT NULL,
    exclusion_reason character varying(20) NOT NULL DEFAULT 'none'::character varying,
    job_id text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    mask_reason character varying,
    CONSTRAINT calib_blanks_pkey PRIMARY KEY (curve_id, method, well)
);


-- ============================================================================
-- Settings cascade + logs
-- ============================================================================

CREATE TABLE IF NOT EXISTS madi_results.calib_settings (
    calib_settings_id bigint NOT NULL DEFAULT nextval('madi_results.calib_settings_calib_settings_id_seq'::regclass),
    project_id integer NOT NULL DEFAULT '-1'::integer,
    study_accession character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    experiment_accession character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    feature character varying(15) NOT NULL DEFAULT '__none__'::character varying,
    antigen character varying(64) NOT NULL DEFAULT '__none__'::character varying,
    param_name character varying(64) NOT NULL,
    param_data_type character varying(15) NOT NULL,
    param_integer_value integer,
    param_numeric_value numeric,
    param_boolean_value boolean,
    param_character_value text,
    param_user text,
    updated_at timestamp with time zone DEFAULT now(),
    param_group character varying(24),
    CONSTRAINT calib_settings_scope_param_uniq UNIQUE (project_id, study_accession, experiment_accession, feature, antigen, param_name),
    CONSTRAINT calib_settings_pkey PRIMARY KEY (calib_settings_id),
    CONSTRAINT calib_settings_antigen_needs_feature_chk CHECK ((((antigen)::text = '__none__'::text) OR ((feature)::text <> '__none__'::text))),
    CONSTRAINT calib_settings_experiment_needs_study_chk CHECK ((((experiment_accession)::text = '__none__'::text) OR ((study_accession)::text <> '__none__'::text))),
    CONSTRAINT calib_settings_feature_needs_experiment_chk CHECK ((((feature)::text = '__none__'::text) OR ((experiment_accession)::text <> '__none__'::text))),
    CONSTRAINT calib_settings_param_data_type_check CHECK (((param_data_type)::text = ANY ((ARRAY['integer'::character varying, 'numeric'::character varying, 'boolean'::character varying, 'character'::character varying])::text[]))),
    CONSTRAINT calib_settings_system_wildcard_chk CHECK (((project_id <> '-1'::integer) OR (((study_accession)::text = '__none__'::text) AND ((experiment_accession)::text = '__none__'::text) AND ((feature)::text = '__none__'::text) AND ((antigen)::text = '__none__'::text))))
);

CREATE TABLE IF NOT EXISTS madi_results.calib_settings_meta (
    param_name character varying(64) NOT NULL,
    param_group character varying(24),
    param_label character varying(256),
    param_data_type character varying(15) NOT NULL,
    param_control_type character varying(64),
    param_choices_list character varying(256),
    param_char_len numeric,
    updated_at timestamp with time zone DEFAULT now(),
    param_description text,
    CONSTRAINT calib_settings_meta_pkey PRIMARY KEY (param_name),
    CONSTRAINT calib_settings_meta_param_data_type_check CHECK (((param_data_type)::text = ANY ((ARRAY['integer'::character varying, 'numeric'::character varying, 'boolean'::character varying, 'character'::character varying])::text[])))
);

CREATE TABLE IF NOT EXISTS madi_results.calib_settings_migration_log (
    project_id integer,
    study_accession character varying(15),
    experiment_accession text,
    antigen character varying(64),
    model_form_list text,
    standard_curve_concentration numeric,
    l_asy_min_constraint numeric,
    l_asy_max_constraint numeric,
    l_asy_constraint_method character varying(40),
    feature text,
    feature_source text,
    n_feat_in_context bigint
);

CREATE TABLE IF NOT EXISTS madi_results.calib_settings_studycfg_log (
    project_id integer,
    study_accession character varying,
    param_name character varying,
    param_group character varying(24),
    param_data_type text,
    param_integer_value integer,
    param_boolean_value boolean,
    param_character_value text,
    study_raw character varying(15),
    param_raw character varying(50)
);


-- ============================================================================
-- Sequence ownership (deferred: references calib_settings, created above).
-- OWNED BY ties the sequence's lifecycle to the column (dropped with it).
-- ============================================================================
ALTER SEQUENCE madi_results.calib_settings_calib_settings_id_seq
    OWNED BY madi_results.calib_settings.calib_settings_id;

-- OWNER is environment-specific (set the correct role when applying to a
-- fresh target):
-- ALTER SEQUENCE madi_results.calib_settings_calib_settings_id_seq OWNER TO <role>;


-- ============================================================================
-- Schema version (0.7.1). One row per component and version applied; the
-- latest row per component is the version in force. Shown by I-SPI and carried
-- in the release manifest. Applying this file records its own version; it must
-- equal curveRcore::calib_schema_version() (a package test checks this).
-- ============================================================================
CREATE TABLE IF NOT EXISTS madi_results.schema_version (
    component text NOT NULL,
    version text NOT NULL,
    description text,
    applied_at timestamp with time zone NOT NULL DEFAULT now(),
    applied_by text NOT NULL DEFAULT current_user,
    CONSTRAINT schema_version_pkey PRIMARY KEY (component, version)
);

INSERT INTO madi_results.schema_version (component, version, description)
VALUES ('calib_schema', '0.7.1',
        'curveRcore calib_* contract: calib_weights_fit.fit_options and fit diagnostics (both weights models)')
ON CONFLICT (component, version) DO NOTHING;
