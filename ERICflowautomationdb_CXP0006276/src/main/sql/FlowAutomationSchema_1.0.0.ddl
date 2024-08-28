-- ##########################################################################
-- # COPYRIGHT Ericsson 2018
-- #
-- # The copyright to the computer program(s) herein is the property of
-- # Ericsson Inc. The programs may be used and/or copied only with written
-- # permission from Ericsson Inc. or in accordance with the terms and
-- # conditions stipulated in the agreement/contract under which the
-- # program(s) have been supplied.
-- ##########################################################################

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'schema_group_types') THEN
        CREATE TYPE schema_group_types AS ENUM ('Camunda', 'FlowAutomation');
    END IF;
END
$$;


CREATE OR REPLACE FUNCTION update_version(pId integer, pSchemaGroup schema_group_types, pVersion text, pComment text, pStatus boolean)
    RETURNS text AS $body$
DECLARE
    total1 integer;
    total2 integer;
    strResult text := '';
BEGIN
    --Insert version for database in the version table.
    INSERT INTO fa_db_version (id, schema_group, version, comments, updated_date, status)
         SELECT pId, pSchemaGroup, pVersion, pComment, now(), pStatus
          WHERE NOT EXISTS (SELECT version FROM fa_db_version WHERE schema_group = pSchemaGroup AND version = pVersion);
    GET DIAGNOSTICS total1 = ROW_COUNT;

    -- Update version status
    IF total1 = 1 THEN
        UPDATE fa_db_version SET status = CASE WHEN schema_group = pSchemaGroup AND version = pVersion THEN true ELSE false END;
        GET DIAGNOSTICS total2 = ROW_COUNT;
        strResult := strResult || total1 || '-' || total2;
    ELSE
        strResult := strResult || total1;
    END IF;

    RETURN strResult;
END;
$body$ LANGUAGE 'plpgsql';


CREATE OR REPLACE FUNCTION create_flowautomation_schema()
  RETURNS void AS $func$
DECLARE
    -- Global variables
    tables integer := 6;
    _is_schemaExists INTEGER;
BEGIN
    SELECT count(*) INTO _is_schemaexists FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('fa_flow', 'fa_flow_detail','fa_flow_execution', 'fa_flow_execution_report_variable', 'fa_flow_execution_event', 'fa_db_version');

    IF _is_schemaExists <> tables THEN

        -- 1. Table to store flows.
        CREATE TABLE fa_flow (
            id                                 BIGSERIAL NOT NULL,
            flow_id                            varchar(255) NOT NULL,
            name                               varchar(255) NOT NULL,
            status                             varchar(64) NOT NULL,
            source                             varchar(64)NOT NULL,
            CONSTRAINT fa_flow_primary_key_constraint PRIMARY KEY(id),
            CONSTRAINT fa_flow_name_unique_constraint UNIQUE(name),
            CONSTRAINT fa_flow_flow_id_unique_constraint UNIQUE(flow_id)
        )
        WITH (
            OIDS=FALSE,
            autovacuum_enabled = true
        );
        CREATE INDEX fa_flow_flow_id_index ON fa_flow USING BTREE (flow_id);

        -- 2. Table to store flow details.
        CREATE TABLE fa_flow_detail (
            id                                  BIGSERIAL NOT NULL,
            fa_flow_id                          BIGSERIAL NOT NULL,
            process_definition_key              varchar(255) NOT NULL,
            version                             varchar(64) NOT NULL,
            description                         text NOT NULL,
            setup_id                            varchar(255),
            execute_id                          varchar(255) NOT NULL,
            imported_by_user                    varchar(64) NOT NULL,
            imported_date                       timestamp with time zone NOT NULL,
            is_active                           bool NOT NULL,
            deployment_id                       varchar(64) NOT NULL,
            back_enabled                        boolean default false,
            CONSTRAINT fa_flow_detail_primary_key_constraint PRIMARY KEY(id),
            CONSTRAINT fa_flow_detail_process_definition_key_unique_constraint UNIQUE(process_definition_key),
            CONSTRAINT Ref_fa_flow_detail_to_fa_flow FOREIGN KEY (fa_flow_id) REFERENCES fa_flow(id) MATCH SIMPLE ON DELETE CASCADE ON UPDATE CASCADE NOT DEFERRABLE
        )
        WITH (
            OIDS=FALSE,
            autovacuum_enabled = true
        );
        CREATE INDEX fa_flow_detail_process_definition_key_index ON fa_flow_detail USING BTREE (process_definition_key);
        CREATE INDEX fa_flow_detail_flow_id_index ON fa_flow_detail USING BTREE (fa_flow_id);

        -- 3. Table to store flow execution.
        CREATE TABLE fa_flow_execution (
            id                                   BIGSERIAL NOT NULL,
            fa_flow_detail_id                    BIGSERIAL NOT NULL,
            process_instance_id                  varchar(64) NOT NULL,
            flow_execution_name                  varchar(255) NOT NULL,
            executed_by_user                     varchar(64) NOT NULL,
            process_instance_business_key        varchar(255),
            CONSTRAINT fa_flow_execution_primary_key_constraint PRIMARY KEY(id),
            CONSTRAINT fa_flow_execution_process_instance_id_unique_constraint UNIQUE(process_instance_id),
            CONSTRAINT Ref_fa_flow_execution_to_fa_flow_detail FOREIGN KEY (fa_flow_detail_id) REFERENCES fa_flow_detail(id) MATCH SIMPLE ON DELETE CASCADE ON UPDATE CASCADE NOT DEFERRABLE
        )
        WITH (
            OIDS=FALSE,
            autovacuum_vacuum_scale_factor = 0,
            autovacuum_vacuum_threshold = 100,
            autovacuum_enabled = true
        );
        CREATE INDEX fa_flow_execution_fa_flow_detail_id_index ON fa_flow_execution USING BTREE (fa_flow_detail_id);
        CREATE INDEX fa_flow_execution_process_instance_id_index ON fa_flow_execution USING BTREE (process_instance_id);

        -- 4. Table to store report variables.
        CREATE TABLE fa_flow_execution_report_variable (
            id                                  BIGSERIAL NOT NULL,
            fa_flow_execution_id                BIGSERIAL NOT NULL,
            name                                varchar(255) NOT NULL,
            value                               text,
            size                                integer,
            created_time                        timestamp with time zone NOT NULL default NOW(),
            CONSTRAINT fa_flow_execution_report_variable_primary_key_constraint PRIMARY KEY(id),
            CONSTRAINT Ref_fa_flow_execution_report_variable_to_fa_flow_execution FOREIGN KEY (fa_flow_execution_id) REFERENCES fa_flow_execution(id) MATCH SIMPLE ON DELETE CASCADE ON UPDATE CASCADE NOT DEFERRABLE
        )
        WITH (
            OIDS=FALSE,
            autovacuum_vacuum_scale_factor = 0,
            autovacuum_vacuum_threshold = 1500,
            autovacuum_enabled = true
        );
        CREATE INDEX fa_flow_execution_report_variable_fa_flow_execution_id_index ON fa_flow_execution_report_variable USING BTREE (fa_flow_execution_id);

        -- 5. Table to store flow execution events recorded by the flow.
        CREATE TABLE fa_flow_execution_event (
            id                                   BIGSERIAL NOT NULL,
            event_time                           timestamp with time zone NOT NULL default NOW(),
            event_severity                       varchar(16) NOT NULL,
            target                               varchar(255),
            message                              text,
            event_data                           text,
            fa_flow_execution_id                 BIGSERIAL NOT NULL,
            CONSTRAINT fa_flow_execution_event_primary_key_constraint PRIMARY KEY(id),
            CONSTRAINT Ref_fa_flow_execution_event_to_fa_flow_execution FOREIGN KEY (fa_flow_execution_id) REFERENCES fa_flow_execution(id) MATCH SIMPLE ON DELETE CASCADE ON UPDATE
            CASCADE NOT DEFERRABLE
        )
        WITH (
            OIDS=FALSE,
            autovacuum_vacuum_scale_factor = 0,
            autovacuum_vacuum_threshold = 1500,
            autovacuum_enabled = true
        );
        CREATE INDEX fa_flow_execution_event_target_event_severity ON fa_flow_execution_event USING BTREE (target,event_severity);
        CREATE INDEX fa_flow_execution_event_event_severity_target ON fa_flow_execution_event USING BTREE (event_severity,target);

        --6. Table Version to handle Camunda DB version for upgrade process.
        CREATE TABLE fa_db_version (
            id                                 integer,
            schema_group                       schema_group_types,
            version                            varchar(11) NOT NULL,
            comments                           varchar(256) NOT NULL,
            updated_date                       timestamp with time zone NOT NULL,
            status                             varchar(64) NOT NULL,
            CONSTRAINT version_pkID PRIMARY KEY (id, schema_group, version)
        )
        WITH (
            OIDS=FALSE,
            autovacuum_vacuum_scale_factor = 0,
            autovacuum_vacuum_threshold = 100,
            autovacuum_enabled = true
        );
    END IF;
END
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_administrator_user_for_Camunda()
    RETURNS void AS $func$
DECLARE

BEGIN

DO $$
BEGIN
  IF NOT EXISTS (SELECT * FROM act_id_user WHERE id_ = 'administrator') THEN
    INSERT INTO public.act_id_user (id_, rev_, first_, last_, email_, pwd_, salt_, lock_exp_time_, attempts_, picture_id_) VALUES ('administrator', 1, 'administrator', 'administrator', '', '{SHA-512}X/xKo/w2RIT+FZGJmF23JztEjmlM2ctf3kYt1JhTCX8HG69oQy2q4Q7la0A9feVvim/tXsvNAPCqa1At8e9Jeg==', 'HPxekiJtn/tZKtWTJNnCkg==', null, null, null);

    INSERT INTO public.act_id_group (id_, rev_, name_, type_) VALUES ('camunda-admin', 1, 'camunda BPM Administrators', 'SYSTEM');

    INSERT INTO public.act_id_membership (user_id_, group_id_) VALUES ('administrator', 'camunda-admin');
  END IF;
END
$$;

END
$func$ LANGUAGE plpgsql;

-- The values in this function need to be reconfigured for IDUN, as they are currently optimised for ENM.
CREATE OR REPLACE FUNCTION enable_auto_vacuum()
  RETURNS void AS $func$
DECLARE

BEGIN

    ALTER TABLE act_ru_job SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 6000, autovacuum_enabled = true);
    ALTER TABLE act_ru_variable SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 5000, autovacuum_enabled = true);
    ALTER TABLE act_ge_bytearray SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 5000, autovacuum_enabled = true);
    ALTER TABLE act_ru_execution SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 5000, autovacuum_enabled = true);
    ALTER TABLE act_hi_procinst SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 2000, autovacuum_enabled = true);
    ALTER TABLE act_ru_ext_task SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_hi_varinst SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_hi_actinst SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_ge_property SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_ge_schema_log SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_attachment SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_batch SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_caseactinst SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_caseinst SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_comment SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_dec_in SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_dec_out SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_decinst SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_detail SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_ext_task_log SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_identitylink SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_incident SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_job_log SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_op_log SET (autovacuum_enabled = true);
    ALTER TABLE act_hi_taskinst  SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_id_group SET (autovacuum_enabled = true);
    ALTER TABLE act_id_info SET (autovacuum_enabled = true);
    ALTER TABLE act_id_membership SET (autovacuum_enabled = true);
    ALTER TABLE act_id_tenant SET (autovacuum_enabled = true);
    ALTER TABLE act_id_tenant_member SET (autovacuum_enabled = true);
    ALTER TABLE act_id_user SET (autovacuum_enabled = true);
    ALTER TABLE act_re_case_def SET (autovacuum_enabled = true);
    ALTER TABLE act_re_decision_def SET (autovacuum_enabled = true);
    ALTER TABLE act_re_decision_req_def SET (autovacuum_enabled = true);
    ALTER TABLE act_re_deployment SET (autovacuum_enabled = true);
    ALTER TABLE act_re_procdef SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_authorization SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_batch SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_ru_case_execution SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_case_sentry_part SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_event_subscr SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_ru_filter SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_identitylink SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_incident SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_jobdef SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);
    ALTER TABLE act_ru_meter_log SET (autovacuum_enabled = true);
    ALTER TABLE act_ru_task SET (autovacuum_vacuum_scale_factor = 0, autovacuum_vacuum_threshold = 100, autovacuum_enabled = true);

END
$func$ LANGUAGE plpgsql;

--Execute functions.
SELECT create_flowautomation_schema();
SELECT create_administrator_user_for_Camunda();
SELECT enable_auto_vacuum();
SELECT update_version(1, 'FlowAutomation', '1.0.0', 'Create Flow Automation Schema', true);

--Drop functions.
DROP FUNCTION create_flowautomation_schema();
DROP FUNCTION create_administrator_user_for_Camunda();
DROP FUNCTION enable_auto_vacuum();
DROP FUNCTION update_version(integer, schema_group_types, text, text, boolean);
