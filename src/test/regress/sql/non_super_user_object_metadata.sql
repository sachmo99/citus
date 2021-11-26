SET citus.enable_ddl_propagation TO OFF;

CREATE SCHEMA local_schema;
SET search_path TO local_schema;

SELECT start_metadata_sync_to_node('localhost', :worker_1_port);

-- Create type and function that depends on it
CREATE TYPE test_type AS (f1 int, f2 text);
CREATE FUNCTION test_function(int) RETURNS test_type
    AS $$ SELECT $1, CAST($1 AS text) || ' is text' $$
    LANGUAGE SQL;

-- Create various objects
CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');
CREATE SEQUENCE test_sequence;

-- show that none of the objects above are marked as distributed
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema'::regnamespace::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.mood'::regtype::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_type'::regtype::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_sequence'::regclass::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_function'::regproc::oid;

SET client_min_messages TO ERROR;
CREATE USER non_super_user_test_user;
SELECT run_command_on_workers($$CREATE USER non_super_user_test_user;$$);
RESET client_min_messages;

GRANT ALL ON SCHEMA local_schema TO non_super_user_test_user;

SET ROLE non_super_user_test_user;
SET search_path TO local_schema;
CREATE TABLE dist_table(a int, b mood, c test_type, d int DEFAULT nextval('test_sequence'), e bigserial);

-- Citus requires that user must own the dependent sequence
-- https://github.com/citusdata/citus/issues/5494
SELECT create_distributed_table('local_schema.dist_table', 'a');

-- Citus requires that user must own the function to distribute
SELECT create_distributed_function('test_function(int)');

RESET ROLE;
SET search_path TO local_schema;
ALTER SEQUENCE test_sequence OWNER TO non_super_user_test_user;
ALTER FUNCTION test_function(int) OWNER TO non_super_user_test_user;

SET ROLE non_super_user_test_user;
SET search_path TO local_schema;

-- Show that we can distribute table and function after
-- having required ownerships
SELECT create_distributed_table('dist_table', 'a');
SELECT create_distributed_function('test_function(int)');

-- show that schema, types, function and sequence has marked as distributed
-- on the coordinator node
RESET ROLE;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema'::regnamespace::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.mood'::regtype::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_type'::regtype::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_sequence'::regclass::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.dist_table_e_seq'::regclass::oid;
SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_function'::regproc::oid;

-- show those objects marked as distributed on metadata worker node as well
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema'::regnamespace::oid;$$);
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.mood'::regtype::oid;$$);
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_type'::regtype::oid;$$);
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_sequence'::regclass::oid;$$);
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.dist_table_e_seq'::regclass::oid;$$);
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object where objid = 'local_schema.test_function'::regproc::oid;$$);

-- show that schema is owned by the superuser
SELECT rolname FROM pg_roles JOIN pg_namespace ON(pg_namespace.nspowner = pg_roles.oid) WHERE nspname = 'local_schema';
SELECT run_command_on_workers($$SELECT rolname FROM pg_roles JOIN pg_namespace ON(pg_namespace.nspowner = pg_roles.oid) WHERE nspname = 'local_schema';$$);

-- show that types are owned by the superuser
SELECT DISTINCT(rolname) FROM pg_roles JOIN pg_type ON(pg_type.typowner = pg_roles.oid) WHERE typname IN ('test_type', 'mood');
SELECT run_command_on_workers($$SELECT DISTINCT(rolname) FROM pg_roles JOIN pg_type ON(pg_type.typowner = pg_roles.oid) WHERE typname IN ('test_type', 'mood');$$);

-- show that table is owned by the non_super_user_test_user
SELECT rolname FROM pg_roles JOIN pg_class ON(pg_class.relowner = pg_roles.oid) WHERE relname = 'dist_table';
SELECT run_command_on_workers($$SELECT rolname FROM pg_roles JOIN pg_class ON(pg_class.relowner = pg_roles.oid) WHERE relname = 'dist_table'$$);

SET ROLE non_super_user_test_user;
SET search_path TO local_schema;

-- ensure we can load data
INSERT INTO dist_table VALUES (1, 'sad', (1,'onder')::test_type),
							  (2, 'ok', (1,'burak')::test_type),
							  (3, 'happy', (1,'marco')::test_type);

SELECT a, b, c , d FROM dist_table ORDER BY 1,2,3,4;

-- Show that dropping the table removes the dependent sequence from pg_dist_object
-- on both coordinator and metadata worker nodes when ddl propagation is on
SET citus.enable_ddl_propagation TO ON;
DROP TABLE dist_table CASCADE;

RESET ROLE;
SET search_path TO local_schema;
SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%sequence%';
SELECT run_command_on_workers($$SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%sequence%';$$);

-- Show that dropping the function removes the metadata from pg_dist_object
-- on both coordinator and metadata worker node
DROP FUNCTION test_function;
SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%test_function%';
SELECT run_command_on_workers($$SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%test_function%';$$);

-- Show that dropping type removes the metadata from pg_dist_object
-- on both coordinator and metadata worker node
DROP TYPE mood CASCADE;
DROP TYPE test_type CASCADE;

SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%test_type%' or obj_identifier::text like '%mood%';
SELECT run_command_on_workers($$SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%test_type%' or obj_identifier::text like '%mood%'$$);

-- Show that dropping schema doesn't affect the worker node
DROP SCHEMA local_schema CASCADE;

SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%{local_schema}%';
SELECT run_command_on_workers($$SELECT * FROM (SELECT pg_identify_object_as_address(classid, objid, objsubid) as obj_identifier from citus.pg_dist_object) as obj_identifiers where obj_identifier::text like '%{local_schema}%';$$);

-- Show that distributed function related metadata are also propagated
set citus.replication_model TO streaming ;

CREATE TABLE test (a int, b int);
SELECT create_distributed_table('test', 'a');
CREATE OR REPLACE PROCEDURE proc(dist_key integer, dist_key_2 integer)
LANGUAGE plpgsql
AS $$ DECLARE
res INT := 0;
BEGIN
    INSERT INTO test VALUES (dist_key);
    SELECT count(*) INTO res FROM test;
    RAISE NOTICE 'Res: %', res;
COMMIT;
END;$$;

-- create a distributed function and show its distribution_argument_index
SELECT create_distributed_function('proc(integer, integer)', 'dist_key', 'test');
SELECT distribution_argument_index FROM citus.pg_dist_object WHERE objid = 'proc'::regproc;
SELECT run_command_on_workers($$ SELECT distribution_argument_index FROM citus.pg_dist_object WHERE objid = 'proc'::regproc;$$);

-- re-distribute and show that now the distribution_argument_index is updated on both the coordinator and workers
SELECT create_distributed_function('proc(integer, integer)', 'dist_key_2', 'test');
SELECT * FROM citus.pg_dist_object WHERE objid = 'proc'::regproc;
SELECT distribution_argument_index FROM citus.pg_dist_object WHERE objid = 'proc'::regproc;
SELECT run_command_on_workers($$ SELECT distribution_argument_index FROM citus.pg_dist_object WHERE objid = 'proc'::regproc;$$);

RESET citus.enable_ddl_propagation;
SELECT stop_metadata_sync_to_node('localhost', :worker_1_port);

-- Show that we don't have any object metadata after stopping syncing
SELECT run_command_on_workers($$SELECT pg_identify_object_as_address(classid, objid, objsubid) from citus.pg_dist_object;$$);
