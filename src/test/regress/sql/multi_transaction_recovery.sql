-- Tests for prepared transaction recovery
SET citus.next_shard_id TO 1220000;

-- reference tables can have placements on the coordinator. Add it so
-- verify we recover transactions which do DML on coordinator placements
-- properly.
SET client_min_messages TO ERROR;
SELECT 1 FROM master_add_node('localhost', :master_port, groupid => 0);
RESET client_min_messages;

-- enforce 1 connection per placement since
-- the tests are prepared for that
SET citus.force_max_query_parallelization TO ON;

-- Disable auto-recovery for the initial tests
ALTER SYSTEM SET citus.recover_2pc_interval TO -1;
SELECT pg_reload_conf();

-- Ensure pg_dist_transaction is empty
SELECT recover_prepared_transactions();

-- Create some "fake" prepared transactions to recover
\c - - - :worker_1_port

BEGIN;
CREATE TABLE should_abort (value int);
PREPARE TRANSACTION 'citus_0_should_abort';

BEGIN;
CREATE TABLE should_commit (value int);
PREPARE TRANSACTION 'citus_0_should_commit';

BEGIN;
CREATE TABLE should_be_sorted_into_middle (value int);
PREPARE TRANSACTION 'citus_0_should_be_sorted_into_middle';

\c - - - :master_port

BEGIN;
CREATE TABLE should_abort (value int);
PREPARE TRANSACTION 'citus_0_should_abort';

BEGIN;
CREATE TABLE should_commit (value int);
PREPARE TRANSACTION 'citus_0_should_commit';

BEGIN;
CREATE TABLE should_be_sorted_into_middle (value int);
PREPARE TRANSACTION 'citus_0_should_be_sorted_into_middle';

SET citus.force_max_query_parallelization TO ON;
-- Add "fake" pg_dist_transaction records and run recovery
INSERT INTO pg_dist_transaction VALUES (1, 'citus_0_should_commit'),
                                       (0, 'citus_0_should_commit');
INSERT INTO pg_dist_transaction VALUES (1, 'citus_0_should_be_forgotten'),
                                       (0, 'citus_0_should_be_forgotten');

SELECT recover_prepared_transactions();
SELECT count(*) FROM pg_dist_transaction;

SELECT count(*) FROM pg_tables WHERE tablename = 'should_abort';
SELECT count(*) FROM pg_tables WHERE tablename = 'should_commit';

-- Confirm that transactions were correctly rolled forward
\c - - - :worker_1_port
SELECT count(*) FROM pg_tables WHERE tablename = 'should_abort';
SELECT count(*) FROM pg_tables WHERE tablename = 'should_commit';

\c - - - :master_port
SET citus.force_max_query_parallelization TO ON;
SET citus.shard_replication_factor TO 2;
SET citus.shard_count TO 2;

-- create_distributed_table may behave differently if shards
-- created via the executor or not, so not checking its value
-- may result multiple test outputs, so instead just make sure that
-- there are at least 2 entries
CREATE TABLE test_recovery (x text);
SELECT create_distributed_table('test_recovery', 'x');
SELECT count(*) >= 2 FROM pg_dist_transaction;

-- create_reference_table should add another 2 recovery records
CREATE TABLE test_recovery_ref (x text);
SELECT create_reference_table('test_recovery_ref');
SELECT count(*) >= 4 FROM pg_dist_transaction;

SELECT recover_prepared_transactions();

-- plain INSERT uses 2PC
INSERT INTO test_recovery VALUES ('hello');
SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Aborted DDL commands should not write transaction recovery records
BEGIN;
ALTER TABLE test_recovery ADD COLUMN y text;
ROLLBACK;
SELECT count(*) FROM pg_dist_transaction;

-- Committed DDL commands should write 4 transaction recovery records
ALTER TABLE test_recovery ADD COLUMN y text;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();
SELECT count(*) FROM pg_dist_transaction;

-- Aborted INSERT..SELECT should not write transaction recovery records
BEGIN;
INSERT INTO test_recovery SELECT x, 'earth' FROM test_recovery;
ROLLBACK;
SELECT count(*) FROM pg_dist_transaction;

-- Committed INSERT..SELECT should write 4 transaction recovery records
INSERT INTO test_recovery SELECT x, 'earth' FROM test_recovery;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Committed INSERT..SELECT via coordinator should write 4 transaction recovery records
INSERT INTO test_recovery (x) SELECT 'hello-'||s FROM generate_series(1,100) s;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Committed COPY should write 4 transaction records
COPY test_recovery (x) FROM STDIN CSV;
hello-0
hello-1
\.

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Create a single-replica table to enable 2PC in multi-statement transactions
SET citus.shard_replication_factor TO 1;
CREATE TABLE test_recovery_single (LIKE test_recovery);

-- creating distributed table should write 2 transaction recovery records
-- one connection/transaction per node
SELECT create_distributed_table('test_recovery_single', 'x');

-- Multi-statement transactions should write 2 transaction recovery records
-- since the transaction block expands the nodes that participate in the
-- distributed transaction
BEGIN;
INSERT INTO test_recovery_single VALUES ('hello-0');
INSERT INTO test_recovery_single VALUES ('hello-2');
COMMIT;
SELECT count(*) FROM pg_dist_transaction;

SELECT recover_prepared_transactions();

-- the same test with citus.force_max_query_parallelization=off
-- should be fine as well
SET citus.force_max_query_parallelization TO OFF;
BEGIN;
INSERT INTO test_recovery_single VALUES ('hello-0');
INSERT INTO test_recovery_single VALUES ('hello-2');
COMMIT;
SELECT count(*) FROM pg_dist_transaction;

SELECT recover_prepared_transactions();

-- slightly more complicated test with citus.force_max_query_parallelization=off
-- should be fine as well
SET citus.force_max_query_parallelization TO OFF;
BEGIN;
SELECT count(*) FROM test_recovery_single WHERE x = 'hello-0';
SELECT count(*) FROM test_recovery_single WHERE x = 'hello-2';
INSERT INTO test_recovery_single VALUES ('hello-0');
INSERT INTO test_recovery_single VALUES ('hello-2');
COMMIT;
SELECT count(*) FROM pg_dist_transaction;


SELECT recover_prepared_transactions();

-- the same test as the above with citus.force_max_query_parallelization=on
-- should be fine as well
SET citus.force_max_query_parallelization TO ON;
BEGIN;
SELECT count(*) FROM test_recovery_single WHERE x = 'hello-0';
SELECT count(*) FROM test_recovery_single WHERE x = 'hello-2';
INSERT INTO test_recovery_single VALUES ('hello-0');
INSERT INTO test_recovery_single VALUES ('hello-2');
COMMIT;
SELECT count(*) FROM pg_dist_transaction;

-- check that read-only participants skip prepare
SET citus.shard_count TO 4;
CREATE TABLE test_2pcskip (a int);
SELECT create_distributed_table('test_2pcskip', 'a');
INSERT INTO test_2pcskip SELECT i FROM generate_series(0, 5)i;
SELECT recover_prepared_transactions();

SELECT shardid INTO selected_shard FROM pg_dist_shard WHERE logicalrelid='test_2pcskip'::regclass LIMIT 1;
SELECT COUNT(*) FROM pg_dist_transaction;
BEGIN;
SET LOCAL citus.defer_drop_after_shard_move TO OFF;
SELECT citus_move_shard_placement((SELECT * FROM selected_shard), 'localhost', :worker_1_port, 'localhost', :worker_2_port);
COMMIT;
SELECT COUNT(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

SELECT citus_move_shard_placement((SELECT * FROM selected_shard), 'localhost', :worker_2_port, 'localhost', :worker_1_port);


-- for the following test, ensure that 6 and 7 go to different shards on different workers
SELECT count(DISTINCT nodeport) FROM pg_dist_shard_placement WHERE shardid IN (get_shard_id_for_distribution_column('test_2pcskip', 6),get_shard_id_for_distribution_column('test_2pcskip', 7));
-- only two of the connections will perform a write (INSERT)
SET citus.force_max_query_parallelization TO ON;
BEGIN;
-- these inserts use two connections
INSERT INTO test_2pcskip VALUES (6);
INSERT INTO test_2pcskip VALUES (7);
-- we know this will use more than two connections
SELECT count(*) FROM test_2pcskip;
COMMIT;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- only two of the connections will perform a write (INSERT)
BEGIN;
-- this insert uses two connections
INSERT INTO test_2pcskip SELECT i FROM generate_series(6, 7)i;
-- we know this will use more than two connections
SELECT COUNT(*) FROM test_2pcskip;
COMMIT;

SELECT count(*) FROM pg_dist_transaction;

-- check that reads from a reference table don't trigger 2PC
-- despite repmodel being 2PC
CREATE TABLE test_reference (b int);
SELECT create_reference_table('test_reference');
INSERT INTO test_reference VALUES(1);
INSERT INTO test_reference VALUES(2);
SELECT recover_prepared_transactions();

BEGIN;
SELECT * FROM test_reference ORDER BY 1;
COMMIT;

SELECT count(*) FROM pg_dist_transaction;
SELECT recover_prepared_transactions();

-- Test whether auto-recovery runs
ALTER SYSTEM SET citus.recover_2pc_interval TO 10;
SELECT pg_reload_conf();
-- Sleep 1 second to give Valgrind enough time to clear transactions
SELECT pg_sleep(1);
SELECT count(*) FROM pg_dist_transaction;

ALTER SYSTEM RESET citus.recover_2pc_interval;
SELECT pg_reload_conf();

DROP TABLE test_recovery_ref;
DROP TABLE test_recovery;
DROP TABLE test_recovery_single;
DROP TABLE test_2pcskip;
DROP TABLE test_reference;

SELECT 1 FROM master_remove_node('localhost', :master_port);
