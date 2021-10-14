DROP SCHEMA IF EXISTS distributed_transaction_function CASCADE;
CREATE SCHEMA distributed_transaction_function;
SET search_path TO 'distributed_transaction_function';
SET citus.shard_replication_factor = 1;
SET citus.shard_count = 32;
SET citus.next_shard_id TO 900000;

CREATE TABLE test_txn_dist(intcol int PRIMARY KEY);
SELECT create_distributed_table('test_txn_dist', 'intcol', colocate_with := 'none');

CREATE FUNCTION insert_data(a integer, b integer)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
	INSERT INTO distributed_transaction_function.test_txn_dist VALUES (a);
	INSERT INTO distributed_transaction_function.test_txn_dist VALUES (b);
END;
$fn$;

SELECT create_distributed_function(
  'insert_data(int, int)', 'a',
  colocate_with := 'test_txn_dist',
  force_pushdown := true
);

SET client_min_messages TO DEBUG1;
SET citus.log_remote_commands TO on;

SELECT 'Transaction with no errors' Testing;
BEGIN;
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (1);
-- This call will insert both the rows locally on the remote worker
SELECT insert_data(2, 4);
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (3);
COMMIT;

SELECT 'Transaction with duplicate error in the remote function' Testing;
BEGIN;
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (10);
-- This call will fail with duplicate error on the remote worker
SELECT insert_data(11, 11);
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (12);
COMMIT;

SELECT 'Transaction with duplicate error in the local statement' Testing;
BEGIN;
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (20);
-- This call will insert both the rows locally on the remote worker
SELECT insert_data(21, 22);
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (23);
-- This will fail
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (23);
COMMIT;

SELECT 'Transaction with function doing remote connection' Testing;
BEGIN;
-- This statement will pass
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (30);
-- This call will insert both one rows locally and another on a different node
SELECT insert_data(31, 33);
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (34);
COMMIT;

SELECT 'Transaction with no errors but with a rollback' Testing;
BEGIN;
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (40);
-- This call will insert both the rows locally on the remote worker
SELECT insert_data(41, 42);
INSERT INTO distributed_transaction_function.test_txn_dist VALUES (43);
ROLLBACK;

--
-- Add function with pushdown=true in the targetList of a query
--
BEGIN;
SELECT insert_data(intcol+50, 55 ) from test_txn_dist where intcol = 1;
SELECT insert_data(52, 53);
COMMIT;

-- This should have only the first 4 rows as all other transactions were rolled back.
SELECT * FROM distributed_transaction_function.test_txn_dist ORDER BY 1;

--
-- Nested call, function with pushdown=false calling function with pushdown=true
--
CREATE TABLE test_nested (id int, name text);
SELECT create_distributed_table('test_nested','id');
INSERT INTO test_nested VALUES (100,'hundred');
INSERT INTO test_nested VALUES (200,'twohundred');
INSERT INTO test_nested VALUES (300,'threehundred');
INSERT INTO test_nested VALUES (400,'fourhundred');

CREATE OR REPLACE FUNCTION inner_function(int)
RETURNS NUMERIC AS $$
DECLARE ret_val NUMERIC;
BEGIN
        SELECT max(id)::numeric+1 INTO ret_val  FROM distributed_transaction_function.test_nested WHERE id = $1;
	RAISE NOTICE 'inner_function():%', ret_val;
        RETURN ret_val;
END;
$$  LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION func_calls_dist_func()
RETURNS NUMERIC AS $$
DECLARE incremented_val NUMERIC;
BEGIN
	-- Constant distribution argument
	SELECT inner_function INTO incremented_val FROM inner_function(100);
	RETURN incremented_val;
END;
$$  LANGUAGE plpgsql;

SELECT create_distributed_function('func_calls_dist_func()');
SELECT create_distributed_function('inner_function(int)', '$1', colocate_with := 'test_nested', force_pushdown := true);

BEGIN;
SELECT func_calls_dist_func();
COMMIT;

SELECT func_calls_dist_func();

CREATE OR REPLACE FUNCTION get_val()
RETURNS INT AS $$
BEGIN
        RETURN 100::INT;
END;
$$  LANGUAGE plpgsql;

--
-- UDF calling another UDF using FROM clause
-- fn()
-- {
--   select res into var from fn();
-- }
--
CREATE OR REPLACE FUNCTION func_calls_dist_func_nonconst1()
RETURNS NUMERIC AS $$
DECLARE incremented_val NUMERIC;
DECLARE add_val INT;
BEGIN
	add_val := get_val();
	SELECT inner_function INTO incremented_val FROM inner_function(add_val + 100);
	RETURN incremented_val;
END;
$$  LANGUAGE plpgsql;
RESET client_min_messages;

SELECT func_calls_dist_func_nonconst1();

BEGIN;
SELECT func_calls_dist_func_nonconst1();
COMMIT;

--
-- UDF calling another UDF in the SELECT targetList
-- fn()
-- {
--   select fn() into var;
-- }
--
CREATE OR REPLACE FUNCTION func_calls_dist_func_nonconst2()
RETURNS NUMERIC AS $$
DECLARE incremented_val NUMERIC;
DECLARE add_val INT;
BEGIN
	add_val := get_val();
	--
	-- Note: Adding OFFSET 0 to make it non-simple expression to avoid
	-- the ERROR:  unexpected plan node type: 35 (Custom Scan node)
	--
	SELECT inner_function(100 + 100) INTO incremented_val OFFSET 0;
	RETURN incremented_val;
END;
$$  LANGUAGE plpgsql;
RESET client_min_messages;

SELECT func_calls_dist_func_nonconst2();

BEGIN;
SELECT func_calls_dist_func_nonconst2();
COMMIT;

--
-- Recursive function call with pushdown=true
--
CREATE OR REPLACE FUNCTION test_recursive(inp integer)
RETURNS INT AS $$
DECLARE var INT;
BEGIN
	RAISE NOTICE 'input:%', inp;
	if (inp > 1) then
		var := distributed_transaction_function.test_recursive(inp-1);
		RETURN var;
	else
		RETURN inp;
	END if;
END;
$$  LANGUAGE plpgsql;

SELECT create_distributed_function('test_recursive(int)', '$1', colocate_with := 'test_nested', force_pushdown := true);

BEGIN;
SELECT test_recursive(5);
END;

--
-- Non constant distribution arguments
--

-- Var node e.g. select fn(col) from table where col=150;
BEGIN;
SELECT inner_function(id) FROM test_nested WHERE id = 300;
END;

-- Param(PARAM_EXEC) node e.g. SELECT fn((SELECT col from test_nested where col=val))
BEGIN;
SELECT inner_function((SELECT id FROM test_nested WHERE id=400));
END;

DROP SCHEMA distributed_transaction_function CASCADE;
