---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

- [Presentation Legenda/General dos/Personal notes](#presentation-legendageneral-dospersonal-notes)
- [Preset MySQL configuration, and general tooling introduction](#preset-mysql-configuration-and-general-tooling-introduction)
- [Differences](#differences)
  - [Curiosity: innodb_data_file_path](#curiosity-innodb_data_file_path)
  - [First step before upgrading: output and compare the global system variables](#first-step-before-upgrading-output-and-compare-the-global-system-variables)
  - [SQL mode: `NO_AUTO_CREATE_USER`](#sql-mode-no_auto_create_user)
  - [Optimizer switches: `use_invisible_indexes=off`](#optimizer-switches-use_invisible_indexesoff)
  - [Optimizer switches: `skip_scan=on` (Skip scan range optimization)](#optimizer-switches-skip_scanon-skip-scan-range-optimization)
    - [Loose index scan (OPTIONAL)](#loose-index-scan-optional)
  - [Optimizer switches: `hash_join=on`](#optimizer-switches-hash_joinon)
    - [EXPLAIN issues](#explain-issues)
  - [`information_schema_stats_expiry`](#information_schema_stats_expiry)
  - [`innodb_flush_neighbors`](#innodb_flush_neighbors)
  - [`innodb_max_dirty_pages_pct_lwm`, `innodb_max_dirty_pages_pct`](#innodb_max_dirty_pages_pct_lwm-innodb_max_dirty_pages_pct)
  - [`innodb_stats_sample_pages`](#innodb_stats_sample_pages)
  - [Query caching is gone!](#query-caching-is-gone)
  - [GROUP BY not implicitly sorted anymore](#group-by-not-implicitly-sorted-anymore)
    - [SQL overview](#sql-overview)
    - [Isolating `GROUP BY`s without `ORDER` in the codebase](#isolating-group-bys-without-order-in-the-codebase)
  - [utf8mb4](#utf8mb4)
    - [Improvements of the collation](#improvements-of-the-collation)
    - [Connection configuration](#connection-configuration)
    - [Collation coercion, and issues `general` <> `0900_ai`](#collation-coercion-and-issues-general--0900_ai)
      - [Case 1: Success](#case-1-success)
      - [Case 2: Success](#case-2-success)
      - [Case 3: Failure](#case-3-failure)
      - [Case 4: Other failure](#case-4-other-failure)
    - [Issues with `0900_ai` trailing space](#issues-with-0900_ai-trailing-space)
    - [Issue with triggers](#issue-with-triggers)
    - [Behavior with indexes](#behavior-with-indexes)
    - [Columns/indexes now have less chars available](#columnsindexes-now-have-less-chars-available)
    - [Mac Homebrew default collation](#mac-homebrew-default-collation)
  - [TempTable engine](#temptable-engine)
  - [Gh-ost currently doesn't work!](#gh-ost-currently-doesnt-work)

## Presentation Legenda/General dos/Personal notes

| Label | Explanation |
| ---- | ---- |
| `WRITE` | section to write (or generic thing to do) |
| `STUDY` | subject to study and write|
| `EXPLAIN` | subject to bring up |
| `OPTIONAL` | subject to potentially bring up |

## Preset MySQL configuration, and general tooling introduction

```sh
ln -sf /home/saverio/code/myblog/files/WIP_fosdem_mysql_8_upgrade.cnf ~/.my.cnf

cat ~/.my.cnf

cat ~/bin/mystop
cat ~/bin/mystart
```

## Differences

### Curiosity: innodb_data_file_path

In MySQL 8.0, the system tablespace can be placed anywhere! Example:

```
datadir                   = /home/saverio/databases/mysql_data
innodb_data_home_dir      = /home/saverio/databases/innodb_data/
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend			# Won't work on v5.7, because it's an absolute path
```

In real world, one could/would place the system tablespace and the redo log in the same disk, separate from the tablespace(s) with data. In such case, the configuration would be more like:

```
datadir                   = /home/saverio/databases/mysql_data
innodb_log_group_home_dir = /dev/shm/mysql_logs
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend
```

Filed bug about documentation.

The system tablespace curently includes:

- Doublewrite buffer
- Change buffer: buffer for secondary index changes, which can potentially be merged at a later time

Previously, it included:

- Undo tablespaces (logs): information about how to rollback changes made by a transaction; now in dedicated tablespace(s)
- InnoDB data dictionary: now stored in the MySQL data dictionary

- OPTIONAL: how to turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments
- OPTIONAL/STUDY: debate about doublewrite (read sources)

### First step before upgrading: output and compare the global system variables

EXPLAIN: general idea: get a nice, ordered table

```sh
cd ~/local

ln -sfn mysql-5* mysql # then show

mystart files/WIP_fosdem_mysql_8_upgrade.cnf

# EXPLAIN: why `-t`
# EXPLAIN: long ones - we need to filter
mysql -te 'SHOW GLOBAL VARIABLES' | vim -

# EXPLAIN: SHOW ... WHERE
# EXPLAIN: RLIKE!
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name     RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.longs.5.7.txt
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.shorts.5.7.txt

mystop

ln -sfn mysql-8* mysql

mystart files/WIP_fosdem_mysql_8_upgrade.cnf

mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name     RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.longs.5.7.txt
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.shorts.5.7.txt

meld ~/Desktop/*longs*
meld ~/Desktop/*shorts*
```

### SQL mode: `NO_AUTO_CREATE_USER`

This used to work on MySQL 5.7:

```sql
SELECT * FROM mysql.user WHERE User = 'saverio';
# none

GRANT ALL ON *.* TO saverio@'%';
# success
```

It fails on MySQL 8.0:

```sql
SELECT * FROM mysql.user WHERE User = 'saverio';
# none

GRANT ALL ON *.* TO saverio@'%';
ERROR 1410 (42000): You are not allowed to create a user with GRANT
```

It needs to be manually created:

```sql
CREATE USER saverio@'%' IDENTIFIED BY 'pwd';
# success

GRANT ALL ON *.* TO saverio@'%';
# success
```

### Optimizer switches: `use_invisible_indexes=off`

- OPTIONAL/STUDY: invisible indexes

### Optimizer switches: `skip_scan=on` (Skip scan range optimization)

Source: https://dev.mysql.com/doc/refman/8.0/en/range-optimization.html.

- for each distinct f1 value, perform a subrange scan (f1, {f2_condition})

Data:

```sql
CREATE TABLE ss (f1 INT NOT NULL, f2 INT NOT NULL, PRIMARY KEY(f1, f2));

INSERT INTO ss VALUES (1,1), (1,2), (1,3), (1,4), (1,5), (2,1), (2,2), (2,3), (2,4), (2,5);
INSERT INTO ss SELECT f1, f2 + 5 FROM ss;
INSERT INTO ss SELECT f1, f2 + 10 FROM ss;
INSERT INTO ss SELECT f1, f2 + 20 FROM ss;
INSERT INTO ss SELECT f1, f2 + 40 FROM ss;

ANALYZE TABLE ss;
```

Comparison!:

```sh
meld \
  <(mysql -e "EXPLAIN FORMAT=JSON SELECT /*+ NO_SKIP_SCAN(ss) */ f1, f2 FROM ss WHERE f2 > 40\G") \
  <(mysql -e "EXPLAIN FORMAT=JSON SELECT                         f1, f2 FROM ss WHERE f2 > 40\G")
```

B+trees references:
- https://use-the-index-luke.com/sql/anatomy/slow-indexes
- http://mlwiki.org/index.php/B-Tree#Range_Lookups

(Some) index access types:
- Index unique scan: a single traverse
- Range scan: Index unique scan + leaves traversal

- OPTIONAL: Find out the corresponding code in the `mysql-server` project source code.

#### Loose index scan (OPTIONAL)

- Reference: https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html

```sql
CREATE TABLE lis (f1 INT, f2 INT, KEY (f1, f2));

INSERT INTO lis VALUES (1, 1), (2, 1), (2, 1), (3, 1);
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;

ANALYZE TABLE lis;

meld \
  <(mysql -e "EXPLAIN FORMAT=JSON SELECT /*+ NO_RANGE_OPTIMIZATION(lis) */ f1, MIN(f2) FROM lis GROUP BY f1\G") \
  <(mysql -e "EXPLAIN FORMAT=JSON SELECT                                   f1, MIN(f2) FROM lis GROUP BY f1\G") \
```

### Optimizer switches: `hash_join=on`

Sources:

- https://dev.mysql.com/worklog/task/?id=2241#tabs-2241-4
- https://www.percona.com/blog/2019/10/30/understanding-hash-joins-in-mysql-8

```sql
CREATE TABLE hj1 (c1 INT);

INSERT INTO hj1 VALUES (1), (2), (3), (4);
INSERT INTO hj1 SELECT 131072 * RAND() FROM hj1 a JOIN hj1 b;
INSERT INTO hj1 SELECT 131072 * RAND() FROM hj1 a JOIN hj1 b;
INSERT INTO hj1 SELECT 131072 * RAND() FROM hj1 a JOIN hj1 b;

CREATE TABLE hj2 (c1 INT);

INSERT INTO hj2 SELECT * FROM hj1;

EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM hj1 JOIN hj2 USING (c1)\G
-- -> Aggregate: count(0)
--     -> Inner hash join (hj2.c1 = hj1.c1)  (cost=3138584750.70 rows=3138566607)
--         -> Table scan on hj2  (cost=0.01 rows=177160)
--         -> Hash
--             -> Table scan on hj1  (cost=17804.25 rows=177160)
```

Internally, MySQL builds an in-memory hash table from a chosen "build" table, then iterates the other, "probe" table.

If the build table doesn't fit in memory, then smaller (build) ones are created, and for each, one full probe scanning is performed.

Clarify the conditionals: *all* tables must be equijoins, no LEFT/RIGHT joins.

Filed bug about other EXPLAIN formats not showing the correct strategy.

- OPTIONAL: PHP methods hashing.

#### EXPLAIN issues

Hash join plans currently show only in `EXPLAIN FORMAT=TREE`.

Both in the standard and JSON format, they show as BLock Nested loop:

```sql
EXPLAIN SELECT COUNT(*) FROM hj1 JOIN hj2 USING (c1);
-- +----+-------------+-------+------------+------+---------------+------+---------+------+--------+----------+----------------------------------------------------+
-- | id | select_type | table | partitions | type | possible_keys | key  | key_len | ref  | rows   | filtered | Extra                                              |
-- +----+-------------+-------+------------+------+---------------+------+---------+------+--------+----------+----------------------------------------------------+
-- |  1 | SIMPLE      | hj1   | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 177160 |   100.00 | NULL                                               |
-- |  1 | SIMPLE      | hj2   | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 177160 |    10.00 | Using where; Using join buffer (Block Nested Loop) |
-- +----+-------------+-------+------------+------+---------------+------+---------+------+--------+----------+----------------------------------------------------+

EXPLAIN FORMAT=JSON SELECT COUNT(*) FROM hj1 JOIN hj2 USING (c1)\G
-- {
--   "query_block": {
--     "select_id": 1,
--     "cost_info": {
--       "query_cost": "3138584750.70"
--     },
--     "nested_loop": [
--       {
--         "table": {
--           "table_name": "hj1",
--         [...]
--       },
--       {
--         "table": {
--           "table_name": "hj2",
--           "access_type": "ALL",
--           "rows_examined_per_scan": 177160,
--           "rows_produced_per_join": 3138566606,
--           "filtered": "10.00",
--           "using_join_buffer": "Block Nested Loop",
--         [...]
--       }
--     ]
--   }
-- }
```

Additionally, the cost of the `TREE` format is not correct:

```sql
-- -> Aggregate: count(0)
--     -> Inner hash join (hj2.c1 = hj1.c1)  (cost=3138584750.70 rows=3138566607)
--         [...]
```

### `information_schema_stats_expiry`

[Reference](https://dev.mysql.com/doc/refman/8.0/en/statistics-table.html)

```sql
CREATE TABLE mytable (id INT AUTO_INCREMENT PRIMARY KEY);

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'mytable';
# +------------+----------------+
# | TABLE_NAME | AUTO_INCREMENT |
# +------------+----------------+
# | mytable    |           NULL |
# +------------+----------------+

INSERT INTO mytable VALUES (1);

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'mytable';
# +------------+----------------+
# | TABLE_NAME | AUTO_INCREMENT |
# +------------+----------------+
# | mytable    |           NULL |
# +------------+----------------+

ANALYZE TABLE mytable;

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'mytable';
# +------------+----------------+
# | TABLE_NAME | AUTO_INCREMENT |
# +------------+----------------+
# | mytable    |              2 |
# +------------+----------------+

DROP TABLE mytable;
```

### `innodb_flush_neighbors`

> When the table data is stored on a traditional HDD storage device, flushing such neighbor pages in one operation reduces I/O overhead (primarily for disk seek operations) compared to flushing individual pages at different times
> [...] buffer pool flushing is performed by page cleaner threads

### `innodb_max_dirty_pages_pct_lwm`, `innodb_max_dirty_pages_pct`

> Buffer pool flushing is initiated when the percentage of dirty pages reaches the low water mark value defined by the `innodb_max_dirty_pages_pct_lwm` variable. The default low water mark is 10% of buffer pool pages.
> The purpose of the `innodb_max_dirty_pages_pct_lwm` threshold is to control the percentage dirty pages in the buffer pool, and to prevent the amount of dirty pages from reaching the threshold defined by the `innodb_max_dirty_pages_pct` variable, which has a default value of 90. InnoDB aggressively flushes buffer pool pages if the percentage of dirty pages in the buffer pool reaches the innodb_max_dirty_pages_pct threshold.

Previous values: respectively, 10 and 75.

### `innodb_stats_sample_pages`

Split into `innodb_stats_persistent_sample_pages` and `innodb_stats_transient_sample_pages` (depending on`innodb_stats_persistent`).

Case where it helped us: column with few (in proportion) non-NULL values.

### Query caching is gone!

In a nutshell, query caching can be expensive to maintain in highly concurrent contexts, and even more so, cause contention.

References:

- https://mysqlserverteam.com/mysql-8-0-retiring-support-for-the-query-cache
- https://www.percona.com/blog/2015/01/02/the-mysql-query-cache-how-it-works-and-workload-impacts-both-good-and-bad
- http://www.markleith.co.uk/2010/09/24/tracking-mutex-locks-in-a-process-list-mysql-55s-performance_schema

- OPTIONAL/STUDY: how to analyze query caching savings in a running system with MySQL 5.7 (at a minimum, examine the query used for checking contention)

### GROUP BY not implicitly sorted anymore

#### SQL overview

- Reference: https://mysqlserverteam.com/removal-of-implicit-and-explicit-sorting-for-group-by

MySQL 5.7:

```sql
CREATE TABLE gb (f1 INT, f2 INT);

INSERT INTO gb VALUES (1, 1), (2, 2), (3, 3), (4, 4);
INSERT INTO gb SELECT a.f1, a.f2 + 1 FROM gb `a` JOIN gb `b`;
INSERT INTO gb SELECT a.f1, a.f2 + 10 FROM gb `a` JOIN gb `b`;
INSERT INTO gb SELECT a.f1, a.f2 + 100 FROM gb `a` JOIN gb `b`;

ANALYZE TABLE gb;

-- Copy to file or meld
--
EXPLAIN FORMAT=JSON SELECT f1, SUM(f2) FROM gb GROUP BY f1\G
/* {
  "query_block": {
    "select_id": 1,
    "cost_info": {
      "query_cost": "212421.00"
    },
    "grouping_operation": {
      "using_temporary_table": true,
      "using_filesort": true,
      "cost_info": {
        "sort_cost": "176670.00"
      },
      "table": {
        "table_name": "gb",
        "access_type": "ALL",
        "rows_examined_per_scan": 176670,
        "rows_produced_per_join": 176670,
        "filtered": "100.00",
        "cost_info": {
          "read_cost": "417.00",
          "eval_cost": "35334.00",
          "prefix_cost": "35751.00",
          "data_read_per_join": "2M"
        },
        "used_columns": [
          "f1",
          "f2"
        ]
      }
    }
  }
} */
```

MySQL 8.0:

```sql
CREATE TABLE gb (f1 INT, f2 INT);

INSERT INTO gb VALUES (1, 1), (2, 2), (3, 3), (4, 4);
INSERT INTO gb SELECT a.f1, a.f2 + 1 FROM gb `a` JOIN gb `b`;
INSERT INTO gb SELECT a.f1, a.f2 + 10 FROM gb `a` JOIN gb `b`;
INSERT INTO gb SELECT a.f1, a.f2 + 100 FROM gb `a` JOIN gb `b`;

ANALYZE TABLE gb;

EXPLAIN FORMAT=JSON SELECT f1, SUM(f2) FROM gb GROUP BY f1\G
/* {
  "query_block": {
    "select_id": 1,
    "cost_info": {
      "query_cost": "17771.25"
    },
    "grouping_operation": {
      "using_temporary_table": true,
      "using_filesort": false,
      "table": {
        "table_name": "gb",
        "access_type": "ALL",
        "rows_examined_per_scan": 176670,
        "rows_produced_per_join": 176670,
        "filtered": "100.00",
        "cost_info": {
          "read_cost": "104.25",
          "eval_cost": "17667.00",
          "prefix_cost": "17771.25",
          "data_read_per_join": "2M"
        },
        "used_columns": [
          "f1",
          "f2"
        ]
      }
    }
  }
} */
```

The sort cost is (estimated) to be a very large part of the query!

#### Isolating `GROUP BY`s without `ORDER` in the codebase

```sh
cat > /tmp/test1 << SQL
  GROUP BY col1
  ends here

  GROUP BY col2
  ORDER BY col2

  GROUP BY col3
  ends here

  GROUP BY col4
SQL

cat > /tmp/test2 << SQL
  GROUP BY col5
  ORDER BY col5
SQL

# Basic version: manually inspect with grep.
#
grep -A 1 'GROUP BY' /tmp/test*

# Perl, with some simple logic (previous/current)
#
# Make Perl speak english :-) Capital `M`, don't forget.
#
perl -MEnglish -ne 'print "$ARGV: $previous $ARG" if $previous =~ /GROUP BY/ && !/ORDER BY/; $previous = $ARG' /tmp/test*

# Make Perl print the filenames, and send them so an editor.
#
# Watch out the newline!
#
# Notes:
# - `-l` adds the newline automatically
# - we're ignoring filenames duplication
#
perl -MEnglish -ne 'print "$ARGV\n" if $previous =~ /GROUP BY/ && !/ORDER BY/; $previous = $ARG' /tmp/test* | xargs subl

# OPTIONAL: Yikes! Negative regex.
#
# See https://stackoverflow.com/a/406408.
# Note that this works because by default, dots don't match newlines.
#
grep -zP 'GROUP BY .+\n((?!ORDER BY ).)*\n' /tmp/test*
```

### utf8mb4

- STUDY: review article utf8mb4

#### Improvements of the collation

Reference: https://mysqlserverteam.com/mysql-8-0-collations-the-devil-is-in-the-details

It's simply more correct on some cases. See:

```sql
-- Å = U+212B
SELECT "Å" = "a" COLLATE utf8mb4_general_ci `result`;
-- +--------+
-- | result |
-- +--------+
-- |      0 |
-- +--------+

SELECT "Å" = "a" `result`; -- Default (COLLATE utf8mb4_0900_ai_ci);
-- +--------+
-- | result |
-- +--------+
-- |      1 |
-- +--------+
```

#### Connection configuration

```sql
SHOW VARIABLES WHERE Variable_name RLIKE '^(character_set|collation)_' AND Variable_name NOT RLIKE 'system|database';
-- +--------------------------+--------------------+
-- | Variable_name            | Value              |
-- +--------------------------+--------------------+
-- | character_set_client     | utf8mb4            |  -- literals sent are assumed to be this; then they're converted to the `character_set_connection``
-- | character_set_connection | utf8mb4            |  -- literals charset
-- | collation_connection     | utf8mb4_0900_ai_ci |  -- literals collation

-- | character_set_results    | utf8mb4            |

-- | character_set_server     | utf8mb4            |  - used for objects
-- | collation_server         | utf8mb4_0900_ai_ci |  - used for objects
-- +--------------------------+--------------------+
```

#### Collation coercion, and issues `general` <> `0900_ai`

Reference: https://dev.mysql.com/doc/refman/8.0/en/charset-collation-coercibility.html

```sql
CREATE TABLE tcolls (
  c3_gen CHAR(1) CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci,
  c4_gen CHAR(1) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci,
  c4_900 CHAR(1) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci
);
INSERT INTO tcolls VALUES('ä', 'ä', 'ä');
```

##### Case 1: Success

```sql
SELECT c3_gen = _utf8mb4'ä' `result` FROM tcolls;
-- +--------+
-- | result |
-- +--------+
-- |      1 |
-- +--------+
```

Easy; it works.

##### Case 2: Success

```sql
SELECT c3_gen = _utf8mb4'🍕' COLLATE utf8mb4_bin `result` FROM tcolls;
-- +--------+
-- | result |
-- +--------+
-- |      0 |
-- +--------+
```

In the case above:

- column coercibility value: 2
- explicit collate value:    0

MySQL converts the first value and uses the explicit collation.

##### Case 3: Failure

```sql
SELECT c3_gen = _utf8mb4'🍕' `result` FROM tcolls;
```

Weird? This is because:

- column coerc. value:     2
- implicit collation c.v.: 4

So MySQL tries to convert the second value, and fails!

##### Case 4: Other failure

```sql
SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c3_gen = b.c4_gen;
-- ok

SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c3_gen = b.c4_900;
-- ok

SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c4_gen = b.c4_900;
-- ko!
```

#### Issues with `0900_ai` trailing space

- STUDY: (review article) trailing space due to new collation

```sql
CREATE TABLE sp (
  str VARCHAR(1) CHARSET utf8mb4
);
INSERT INTO sp VALUES(''), (' ');

SHOW VARIABLES WHERE Variable_Name RLIKE '^(character_set|collation)' AND Variable_Name NOT RLIKE 'system|database|dir';

-- +--------------------------+--------------------+
-- | Variable_name            | Value              |
-- +--------------------------+--------------------+
-- | character_set_client     | utf8mb4            |
-- | character_set_connection | utf8mb4            |
-- | character_set_results    | utf8mb4            |
-- | character_set_server     | utf8mb4            |
-- | collation_connection     | utf8mb4_0900_ai_ci |
-- | collation_server         | utf8mb4_0900_ai_ci |
-- +--------------------------+--------------------+

SET GLOBAL NAMES utf8mb4 COLLATE utf8mb4_general_ci;

SHOW VARIABLES WHERE Variable_Name RLIKE '^(character_set|collation)' AND Variable_Name NOT RLIKE 'system|database|dir';

-- +--------------------------+--------------------+
-- | Variable_name            | Value              |
-- +--------------------------+--------------------+
-- | character_set_client     | utf8mb4            |
-- | character_set_connection | utf8mb4            |
-- | character_set_results    | utf8mb4            |
-- | character_set_server     | utf8mb4            |
-- | collation_connection     | utf8mb4_general_ci | <-- here!
-- | collation_server         | utf8mb4_0900_ai_ci |
-- +--------------------------+--------------------+

SELECT CONCAT("'", str, "'") `qstr`, str = '' , str = ' ' FROM sp;
-- ------+----------+-----------+
--  qstr | str = '' | str = ' ' |
-- ------+----------+-----------+
--  ''   |        1 |         1 |
--  ' '  |        1 |         1 |
-- ------+----------+-----------+

SELECT COLLATION_NAME, PAD_ATTRIBUTE FROM information_schema.collations WHERE COLLATION_NAME RLIKE 'utf8(mb4)?_(general|0900_ai)_ci';
-- +--------------------+---------------+
-- | COLLATION_NAME     | PAD_ATTRIBUTE |
-- +--------------------+---------------+
-- | utf8_general_ci    | PAD SPACE     |
-- | utf8mb4_general_ci | PAD SPACE     |
-- | utf8mb4_0900_ai_ci | NO PAD        |
-- +--------------------+---------------+
```

The following are the formal rules from the SQL (2003) standard (section 8.2):

> 3) The comparison of two character strings is determined as follows:
>
> a) Let CS be the collation as determined by Subclause 9.13, “Collation determination”, for the declared
>    types of the two character strings.
>
> b) <u>If the length in characters of X is not equal to the length in characters of Y, then the shorter string is
>    effectively replaced, for the purposes of comparison, with a copy of itself that has been extended to
>    the length of the longer string by concatenation on the right of one or more pad characters</u>, where the
>    pad character is chosen based on CS. <u>If CS has the NO PAD characteristic, then the pad character is
>    an implementation-dependent character</u> different from any character in the character set of X and Y
>    that collates less than any string under CS. Otherwise, the pad character is a \<space\>.
>
> c) The result of the comparison of X and Y is given by the collation CS.
>
> d) Depending on the collation, two strings may compare as equal even if they are of different lengths or
>    contain different sequences of characters. When any of the operations MAX, MIN, and DISTINCT
>    reference a grouping column, and the UNION, EXCEPT, and INTERSECT operators refer to character
>    strings, the specific value selected by these operations from a set of such equal values is implementation-
>    dependent.

```sql
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;

SELECT CONCAT("'", str, "'") `qstr`, str = '' , str = ' ' FROM sp;
-- +------+----------+-----------+
-- | qstr | str = '' | str = ' ' |
-- +------+----------+-----------+
-- | ''   |        1 |         0 |
-- | ' '  |        0 |         1 |
-- +------+----------+-----------+
```

Is there any utf8mb4 0900 collation with `PAD SPACE`?

```sql
SELECT COLLATION_NAME, PAD_ATTRIBUTE FROM information_schema.collations WHERE COLLATION_NAME RLIKE 'utf8.+0900.*_ci';
-- +----------------------------+---------------+
-- | COLLATION_NAME             | PAD_ATTRIBUTE |
-- +----------------------------+---------------+
-- | utf8mb4_0900_ai_ci         | NO PAD        |
-- | utf8mb4_de_pb_0900_ai_ci   | NO PAD        |
-- | utf8mb4_is_0900_ai_ci      | NO PAD        |
-- | utf8mb4_lv_0900_ai_ci      | NO PAD        |
-- | utf8mb4_ro_0900_ai_ci      | NO PAD        |
-- | utf8mb4_sl_0900_ai_ci      | NO PAD        |
-- | utf8mb4_pl_0900_ai_ci      | NO PAD        |
-- | utf8mb4_et_0900_ai_ci      | NO PAD        |
-- | utf8mb4_es_0900_ai_ci      | NO PAD        |
-- | utf8mb4_sv_0900_ai_ci      | NO PAD        |
-- | utf8mb4_tr_0900_ai_ci      | NO PAD        |
-- | utf8mb4_cs_0900_ai_ci      | NO PAD        |
-- | utf8mb4_da_0900_ai_ci      | NO PAD        |
-- | utf8mb4_lt_0900_ai_ci      | NO PAD        |
-- | utf8mb4_sk_0900_ai_ci      | NO PAD        |
-- | utf8mb4_es_trad_0900_ai_ci | NO PAD        |
-- | utf8mb4_la_0900_ai_ci      | NO PAD        |
-- | utf8mb4_eo_0900_ai_ci      | NO PAD        |
-- | utf8mb4_hu_0900_ai_ci      | NO PAD        |
-- | utf8mb4_hr_0900_ai_ci      | NO PAD        |
-- | utf8mb4_vi_0900_ai_ci      | NO PAD        |
-- | utf8mb4_0900_as_ci         | NO PAD        |
-- | utf8mb4_ru_0900_ai_ci      | NO PAD        |
-- +----------------------------+---------------+
```

Ouch! Apps will need to be updated to reflect this.

Conclusion: MySQL doesn't "remove all the trailing spaces" after all 😄

#### Issue with triggers

The trigger properties can be handled like the client charset/collation, however, it's crucial not to forget to change `COLLATION` modifiers inside the triggers.

```sql
SHOW CREATE TRIGGER enqueue_comments_update_instance_event\G

-- Edited version
--
*************************** 1. row ***************************
SQL Original Statement:
CREATE TRIGGER `enqueue_comments_update_instance_event`
AFTER UPDATE ON `comments`
FOR EACH ROW
trigger_body: BEGIN
  SET @changed_fields := NULL;

  IF NOT (OLD.description <=> NEW.description COLLATE utf8_bin AND CHAR_LENGTH(OLD.description) <=> CHAR_LENGTH(NEW.description)) THEN
    SET @changed_fields := CONCAT_WS(',', @changed_fields, 'description');
  END IF;

  IF @changed_fields IS NOT NULL THEN
    SET @old_values := NULL;
    SET @new_values := NULL;

    INSERT INTO instance_events(created_at, instance_type, instance_id, operation, changed_fields, old_values, new_values)
    VALUES(NOW(), 'Comment', NEW.id, 'UPDATE', @changed_fields, @old_values, @new_values);
  END IF;
END
  character_set_client: utf8mb4
  collation_connection: utf8mb4_0900_ai_ci
    Database Collation: utf8mb4_0900_ai_ci
```

#### Behavior with indexes

Indexes are still usable cross-charset, due to automatic conversion performed by MySQL, as long as one is aware that the values are converted after being read from the index.

```sql
CREATE TABLE ui3 (
  c3 CHAR(1) CHARACTER SET utf8,
  KEY (c3)
);

INSERT INTO ui3
VALUES ('a'), ('b'), ('c'), ('d'), ('e'), ('f'), ('g'), ('h'), ('i'), ('j'), ('k'), ('l'), ('m'),
       ('n'), ('o'), ('p'), ('q'), ('r'), ('s'), ('t'), ('u'), ('v'), ('w'), ('x'), ('y'), ('z');

CREATE TABLE ui4 (
  c4 CHAR(1) CHARACTER SET utf8mb4,
  KEY (c4)
);

INSERT INTO ui4 SELECT * FROM ui3;
```

Querying against a constant yields interesting results:

```sql
EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM ui4 WHERE c4 = _utf8'n';
-- -> Aggregate: count(0)
--     -> Filter: (ui4.c4 = 'n')  (cost=0.35 rows=1)
--         -> Index lookup on ui4 using c4 (c4='n')  (cost=0.35 rows=1)
```

MySQL recognizes that `n` is a valid utf8mb4 character, and matches it directly.

With an index:

```sql
EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM ui3 JOIN ui4 ON c3 = c4;
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
-- | id | select_type | table | partitions | type  | possible_keys | key  | key_len | ref  | rows | filtered | Extra                    |
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
-- |  1 | SIMPLE      | ui3   | NULL       | index | NULL          | c3   | 4       | NULL |   26 |   100.00 | Using index              |
-- |  1 | SIMPLE      | ui4   | NULL       | ref   | c4            | c4   | 5       | func |    1 |   100.00 | Using where; Using index |
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+

EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM ui3 JOIN ui4 ON c3 = c4\G
-- -> Aggregate: count(0)
--     -> Nested loop inner join  (cost=11.95 rows=26)
--         -> Index scan on ui3 using c3  (cost=2.85 rows=26)
--         -> Filter: (convert(ui3.c3 using utf8mb4) = ui4.c4)  (cost=0.25 rows=1)
--             -> Index lookup on ui4 using c4 (c4=convert(ui3.c3 using utf8mb4))  (cost=0.25 rows=1)
```

#### Columns/indexes now have less chars available

utf8mb4 characters will take 33% more, which must stay withing the InnoDB index limit, which is however, high (3072 bytes).

- OPTIONAL/STUDY (3 articles): general considerations about VARCHARs/BLOBs
  - https://dev.mysql.com/doc/refman/8.0/en/char.html
  - [Live view char values storage fragmentation](https://dba.stackexchange.com/a/210430)
  - https://mysqlserverteam.com/externally-stored-fields-in-innodb

> InnoDB encodes fixed-length fields greater than or equal to 768 bytes in length as variable-length fields, which can be stored off-page

#### Mac Homebrew default collation

When MySQL is installed via Homebrew, the default collation is `utf8mb4_general_ci`:

```sh
# Mac's standard grep doesn't support Perl regexes.
#
$ grep "DEFAULT_C" "$(brew formula mysql)"
      -DDEFAULT_CHARSET=utf8mb4
      -DDEFAULT_COLLATION=utf8mb4_general_ci

mysql> SHOW GLOBAL VARIABLES LIKE 'collation_%';
+----------------------+--------------------+
| Variable_name        | Value              |
+----------------------+--------------------+
| collation_connection | utf8mb4_general_ci |
| collation_database   | utf8mb4_general_ci |
| collation_server     | utf8mb4_general_ci |
+----------------------+--------------------+
```

This will cause problems when connecting to an 8.0 server with standard defaults.

I've opened an issue and provided a PR to the project.

There are two approaches.

1. Rebuild the clients with an updated formula:

```sh
# Delete the related configuration options; can be done manually.
#
$ formula_filename=$(brew formula mysql)

$ perl -i.bak -ne "print unless /CHARSET|COLLATION/" "$formula_filename"

$ brew reinstall --build-from-source mysql
```

2. Ignore the client encoding on handshake

Setting `character-set-client-handshake = OFF` in the MySQL configuration will impose on the clients the the default server character set.

### TempTable engine

> [...] the TempTable storage engine, which is the default storage engine for in-memory internal temporary tables in MySQL 8.0, supports binary large object types as of MySQL 8.0.13. See Internal Temporary Table Storage Engine.
> The TempTable storage engine provides efficient storage for VARCHAR and VARBINARY columns.

5.7 was:

> Some query conditions prevent the use of an in-memory temporary table, in which case the server uses an on-disk table instead: Presence of a BLOB or TEXT column in the table.
> In-memory temporary tables are managed by the MEMORY storage engine, which uses fixed-length row format. VARCHAR and VARBINARY column values are padded to the maximum column length, in effect storing them as CHAR and BINARY columns.

Demonstration of the point, on MySQL 5.7:

```sql
CREATE TABLE tt (
  f1 INT,
  f2 TEXT
);
INSERT INTO tt VALUES (1, 'a'), (2, 'a'), (3, 'a'), (3, 'b');

EXPLAIN SELECT f1, GROUP_CONCAT(f2) FROM tt GROUP BY f1;
-- +----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------+
-- | id | select_type | table | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra           |
-- +----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------+
-- |  1 | SIMPLE      | tt    | NULL       | ALL  | NULL          | NULL | NULL    | NULL |    4 |   100.00 | Using temporary |
-- +----+-------------+-------+------------+------+---------------+------+---------+------+------+----------+-----------------+

SHOW GLOBAL STATUS LIKE '%tmp%tables';
-- +-------------------------+-------+
-- | Variable_name           | Value |
-- +-------------------------+-------+
-- | Created_tmp_disk_tables | 12    |
-- | Created_tmp_tables      | 16    |
-- +-------------------------+-------+

SELECT f1, GROUP_CONCAT(f2) FROM tt GROUP BY f1;
-- ...

SHOW GLOBAL STATUS LIKE '%tmp%tables';
-- +-------------------------+-------+
-- | Variable_name           | Value |
-- +-------------------------+-------+
-- | Created_tmp_disk_tables | 13    |
-- | Created_tmp_tables      | 18    |
-- +-------------------------+-------+
```

(note that SHOW GLOBAL STATUS uses a temporary table!)

When trying the same on MySQL 8.0, the `Created_tmp_disk_tables` count is not increased!

### Gh-ost currently doesn't work!

There's a known [showstopper bug](https://github.com/github/gh-ost/issues/687) on the latest Gh-ost release, which prevents operations from succeeding on MySQL 8.

Use `pt-online-schema-change` v3.0.x (v3.1.0 is broken!) or Facebook's OnlineSchemaChange.
