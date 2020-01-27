---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

- [Preset MySQL configuration, and tooling](#preset-mysql-configuration-and-tooling)
- [Curiosity: `innodb_data_file_path` can now reside anywhere!](#curiosity-innodb_data_file_path-can-now-reside-anywhere)
  - [System tablespace changes](#system-tablespace-changes)
- [First step before upgrading: output and compare the global system variables](#first-step-before-upgrading-output-and-compare-the-global-system-variables)
- [utf8mb4](#utf8mb4)
  - [Improvements of the collation](#improvements-of-the-collation)
  - [Connection configuration](#connection-configuration)
  - [Collation coercion, and issues `general` <> `0900_ai`](#collation-coercion-and-issues-general--0900_ai)
    - [Case 1: Success (3_col_gen <> 4_impl_ä)](#case-1-success-3_col_gen--4_impl_ä)
    - [Case 2: Success (3_col_gen <> 4_expl_pizza)](#case-2-success-3_col_gen--4_expl_pizza)
    - [Case 3: Failure (3_col_gen <> 4_impl_pizza)](#case-3-failure-3_col_gen--4_impl_pizza)
    - [Case 4: Other failure (c3_gen <> b.c4_gen, c3_gen <> c4_900, c4_gen <> c4_900)](#case-4-other-failure-c3_gen--bc4_gen-c3_gen--c4_900-c4_gen--c4_900)
  - [Issues with `0900_ai` collation padding](#issues-with-0900_ai-collation-padding)
  - [Issue with triggers](#issue-with-triggers)
  - [Behavior with indexes](#behavior-with-indexes)
  - [Consequences of the increase in (potential) size of char columns](#consequences-of-the-increase-in-potential-size-of-char-columns)
  - [Mac Homebrew default collation](#mac-homebrew-default-collation)
- [SQL mode: `NO_AUTO_CREATE_USER`](#sql-mode-no_auto_create_user)
- [Skip scan range](#skip-scan-range)
  - [Loose index scan (related subject, not 8.0)](#loose-index-scan-related-subject-not-80)
- [Hash join](#hash-join)
  - [Issues with EXPLAIN](#issues-with-explain)
- [`information_schema_stats_expiry`](#information_schema_stats_expiry)
- [`innodb_flush_neighbors`](#innodb_flush_neighbors)
- [`innodb_max_dirty_pages_pct_lwm`, `innodb_max_dirty_pages_pct`](#innodb_max_dirty_pages_pct_lwm-innodb_max_dirty_pages_pct)
- [GROUP BY is now unsorted (not implicitly sorted)](#group-by-is-now-unsorted-not-implicitly-sorted)
  - [SQL overview](#sql-overview)
  - [Searching `GROUP BY`s without `ORDER` in the codebase](#searching-group-bys-without-order-in-the-codebase)
- [TempTable engine](#temptable-engine)
- [Schema migration tool issues](#schema-migration-tool-issues)
- [Questions time](#questions-time)
- [Extra topics](#extra-topics)
  - [Turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments](#turbocharge-mysql-write-capacity-using-an-nvram-device-or-devshm-tmpfs-in-dev-environments)
  - [Negative regex (for GROUP BY)](#negative-regex-for-group-by)
- [Secondary/discarded topics](#secondarydiscarded-topics)
  - [Debate about doublewrite (read sources)](#debate-about-doublewrite-read-sources)
  - [Query caching is gone!](#query-caching-is-gone)
  - [In-depth review of VARCHARs/BLOBs](#in-depth-review-of-varcharsblobs)

## Preset MySQL configuration, and tooling

```sh
ln -sf ~/code/prefosdem-2020-presentation/files/my.cnf ~/.my.cnf

cat ~/.my.cnf

cat ~/bin/mystop
cat ~/bin/mystart
cat ~/code/openscripts/mylast
```

## Curiosity: `innodb_data_file_path` can now reside anywhere!

In MySQL 8.0, the system tablespace can be placed anywhere.

Test the followin on MySQL 5.7 (optionally, with a working configuration) and 8.0:

```
datadir                   = /home/saverio/databases/mysql_data
innodb_data_home_dir      = /dev/shm/mysql_logs
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend			# Won't work on v5.7, because it's an absolute path
```

Filed bug about documentation.

### System tablespace changes

The system tablespace currently includes:

- Doublewrite buffer
- Change buffer: buffer for secondary index changes, which can potentially be merged at a later time

Previously, it included:

- Undo tablespaces (logs): information about how to rollback changes made by a transaction; now in dedicated tablespace(s)
- InnoDB data dictionary: now stored in the MySQL data dictionary

## First step before upgrading: output and compare the global system variables

The general idea is to get a nice, ordered layout for comparing.

Show differences between:

- plain `SHOW`
- `SHOW ... WHERE`
- `SHOW ... RLIKE`

Run on MySQL 5.7; capture the long ones into separate text file, and the short ones into meld:

```sql
SHOW GLOBAL VARIABLES;

SHOW GLOBAL VARIABLES WHERE Variable_name     RLIKE "optimizer_switch|sql_mode";
SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode";
```

Run on MySQL 8:

```sql
SHOW GLOBAL VARIABLES WHERE Variable_name     RLIKE "optimizer_switch|sql_mode";
SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode";
```

## utf8mb4

### Improvements of the collation

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

### Connection configuration

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

### Collation coercion, and issues `general` <> `0900_ai`

Reference: https://dev.mysql.com/doc/refman/8.0/en/charset-collation-coercibility.html

Load `datasets/collation_coercion.sql`.

Explain history of the 0900 decision, and problems with web documentation.

#### Case 1: Success (3_col_gen <> 4_impl_ä)

```sql
SELECT c3_gen = _utf8mb4'ä' `result` FROM tcolls;
-- +--------+
-- | result |
-- +--------+
-- |      1 |
-- +--------+
```

Easy; it works.

Coercion values:

- column:           2
- literal implicit: 4

#### Case 2: Success (3_col_gen <> 4_expl_pizza)

```sql
SELECT c3_gen = _utf8mb4'🍕' COLLATE utf8mb4_bin `result` FROM tcolls;
-- +--------+
-- | result |
-- +--------+
-- |      0 |
-- +--------+
```

Coercion values:

- column:           2
- literal explicit: 0

MySQL converts the first value and uses the explicit collation.

#### Case 3: Failure (3_col_gen <> 4_impl_pizza)

```sql
SELECT c3_gen = _utf8mb4'🍕' `result` FROM tcolls;
```

Weird? This is because:

- column:           2
- literal implicit: 4

So MySQL tries to convert the second value, and fails!

This is a problem if an application is in the migration process, and allows characters outside the "Basic Multilingual Plane" ("BMP").

#### Case 4: Other failure (c3_gen <> b.c4_gen, c3_gen <> c4_900, c4_gen <> c4_900)

```sql
SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c3_gen = b.c4_gen;
-- ok

SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c3_gen = b.c4_900;
-- ok

SELECT COUNT(*) FROM tcolls a JOIN tcolls b ON a.c4_gen = b.c4_900;
-- ko!
```

This is a big problem for application that already migrated to `utf8mb4_general_ci`.

### Issues with `0900_ai` collation padding

(**attention**: must be run on different versions, otherwise, the column collation needs to be taken care of).

Load `collation_padding.sql`; run on MySQL 5.7:

```sql
SHOW VARIABLES WHERE Variable_Name RLIKE '^(character_set|collation)' AND Variable_Name NOT RLIKE 'system|database|dir';

-- +--------------------------+--------------------+
-- | Variable_name            | Value              |
-- +--------------------------+--------------------+
-- | character_set_client     | utf8               |
-- | character_set_connection | utf8               |
-- | character_set_results    | utf8               |
-- | character_set_server     | utf8mb4            |
-- | collation_connection     | utf8_general_ci    | -- Here!
-- | collation_server         | utf8mb4_general_ci |
-- +--------------------------+--------------------+

SELECT CONCAT("'", str, "'") `qstr`, str = '' , str = ' ' FROM cp;
-- ------+----------+-----------+
--  qstr | str = '' | str = ' ' |
-- ------+----------+-----------+
--  ''   |        1 |         1 |
--  ' '  |        1 |         1 |
-- ------+----------+-----------+
```

Load `collation_padding.sql`; run on MySQL 8.0:

```sql
SELECT CONCAT("'", str, "'") `qstr`, str = '' , str = ' ' FROM cp;
-- +------+----------+-----------+
-- | qstr | str = '' | str = ' ' |
-- +------+----------+-----------+
-- | ''   |        1 |         0 |
-- | ' '  |        0 |         1 |
-- +------+----------+-----------+
```

Where does this behavior come from? Let's check the collation (**attention**: it's `SHOW COLLATION`, without `s`).

```sql
SHOW COLLATION WHERE Collation RLIKE 'utf8(mb4)?_(general|0900_ai)_ci';
-- +--------------------+---------+-----+---------+----------+---------+---------------+
-- | Collation          | Charset | Id  | Default | Compiled | Sortlen | Pad_attribute |
-- +--------------------+---------+-----+---------+----------+---------+---------------+
-- | utf8mb4_0900_ai_ci | utf8mb4 | 255 | Yes     | Yes      |       0 | NO PAD        |
-- | utf8mb4_general_ci | utf8mb4 |  45 |         | Yes      |       1 | PAD SPACE     |
-- | utf8_general_ci    | utf8    |  33 | Yes     | Yes      |       1 | PAD SPACE     |
-- +--------------------+---------+-----+---------+----------+---------+---------------+
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

Is there any utf8mb4 0900 collation with `PAD SPACE`?

```sql
SHOW COLLATION WHERE Collation RLIKE 'utf8.+0900_ai_ci';
-- +----------------------------+---------+-----+---------+----------+---------+---------------+
-- | Collation                  | Charset | Id  | Default | Compiled | Sortlen | Pad_attribute |
-- +----------------------------+---------+-----+---------+----------+---------+---------------+
-- | utf8mb4_0900_ai_ci         | utf8mb4 | 255 | Yes     | Yes      |       0 | NO PAD        |
-- | utf8mb4_0900_as_ci         | utf8mb4 | 305 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_cs_0900_ai_ci      | utf8mb4 | 266 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_da_0900_ai_ci      | utf8mb4 | 267 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_de_pb_0900_ai_ci   | utf8mb4 | 256 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_eo_0900_ai_ci      | utf8mb4 | 273 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_es_0900_ai_ci      | utf8mb4 | 263 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_es_trad_0900_ai_ci | utf8mb4 | 270 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_et_0900_ai_ci      | utf8mb4 | 262 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_hr_0900_ai_ci      | utf8mb4 | 275 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_hu_0900_ai_ci      | utf8mb4 | 274 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_is_0900_ai_ci      | utf8mb4 | 257 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_la_0900_ai_ci      | utf8mb4 | 271 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_lt_0900_ai_ci      | utf8mb4 | 268 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_lv_0900_ai_ci      | utf8mb4 | 258 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_pl_0900_ai_ci      | utf8mb4 | 261 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_ro_0900_ai_ci      | utf8mb4 | 259 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_ru_0900_ai_ci      | utf8mb4 | 306 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_sk_0900_ai_ci      | utf8mb4 | 269 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_sl_0900_ai_ci      | utf8mb4 | 260 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_sv_0900_ai_ci      | utf8mb4 | 264 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_tr_0900_ai_ci      | utf8mb4 | 265 |         | Yes      |       0 | NO PAD        |
-- | utf8mb4_vi_0900_ai_ci      | utf8mb4 | 277 |         | Yes      |       0 | NO PAD        |
-- +----------------------------+---------+-----+---------+----------+---------+---------------+
```

Ouch! Apps will need to be updated to reflect this.

Conclusion: MySQL doesn't "remove all the trailing spaces" after all 😄

### Issue with triggers

The trigger properties can be handled like the client charset/collation, however, it's crucial not to forget to change `COLLATION` modifiers inside the triggers.

Edited sample of a trigger:

```sql
SHOW CREATE TRIGGER enqueue_comments_update_instance_event\G

-- SQL Original Statement:
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
--   character_set_client: utf8mb4
--   collation_connection: utf8mb4_0900_ai_ci
--     Database Collation: utf8mb4_0900_ai_ci
```

Suggestion: build an event system based on MySQL triggers, like ActiveTrigger.

### Behavior with indexes

Indexes are still usable cross-charset, due to automatic conversion performed by MySQL, as long as one is aware that the values are converted after being read from the index.

Load `collation_indexes.sql`.

Querying against a constant yields interesting results:

```sql
EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM ci4 WHERE c4 = _utf8'n'\G
-- -> Aggregate: count(0)
--     -> Filter: (ci4.c4 = 'n')  (cost=0.35 rows=1)
--         -> Index lookup on ci4 using c4 (c4='n')  (cost=0.35 rows=1)
```

MySQL recognizes that `n` is a valid utf8mb4 character, and matches it directly.

With an index:

```sql
EXPLAIN SELECT COUNT(*) FROM ci3 JOIN ci4 ON c3 = c4;
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
-- | id | select_type | table | partitions | type  | possible_keys | key  | key_len | ref  | rows | filtered | Extra                    |
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+
-- |  1 | SIMPLE      | ci3   | NULL       | index | NULL          | c3   | 4       | NULL |   26 |   100.00 | Using index              |
-- |  1 | SIMPLE      | ci4   | NULL       | ref   | c4            | c4   | 5       | func |    1 |   100.00 | Using where; Using index |
-- +----+-------------+-------+------------+-------+---------------+------+---------+------+------+----------+--------------------------+

EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM ci3 JOIN ci4 ON c3 = c4\G
-- -> Aggregate: count(0)
--     -> Nested loop inner join  (cost=11.95 rows=26)
--         -> Index scan on ci3 using c3  (cost=2.85 rows=26)
--         -> Filter: (convert(ci3.c3 using utf8mb4) = ci4.c4)  (cost=0.25 rows=1)
--             -> Index lookup on ci4 using c4 (c4=convert(ci3.c3 using utf8mb4))  (cost=0.25 rows=1)
```

### Consequences of the increase in (potential) size of char columns

Reference: https://dev.mysql.com/doc/refman/8.0/en/char.html

utf8mb4 characters will take 33% more, which must stay withing the InnoDB index limit, which is however, high (3072 bytes).

> InnoDB encodes fixed-length fields greater than or equal to 768 bytes in length as variable-length fields, which can be stored off-page

### Mac Homebrew default collation

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

1. Update the formula and rebuild MySQL:

```sh
formula_filename=$(brew formula mysql)

perl -i.bak -ne "print unless /CHARSET|COLLATION/" "$formula_filename"

brew reinstall --build-from-source mysql
```

2. Ignore the client encoding on handshake

Setting `character-set-client-handshake = OFF` in the MySQL configuration will impose on the clients the the default server character set.

## SQL mode: `NO_AUTO_CREATE_USER`

On MySQL 5.7, users could be implicitly created via GRANT:

```sql
GRANT ALL ON *.* TO sav_test@'%';
-- success
```

It fails on MySQL 8.0; it needs to be manually create:

```sql
GRANT ALL ON *.* TO sav_test@'%';
ERROR 1410 (42000): You are not allowed to create a user with GRANT

CREATE USER sav_test@'%' IDENTIFIED BY 'pwd';
-- success

GRANT ALL ON *.* TO sav_test@'%';
-- success
```

It's a design improvement, to decouple users from their permissions. However, note that the backing data still uses a single concept:

```sql
CREATE USER paolo_test;

SELECT * FROM mysql.user WHERE User = 'paolo_test'\G
```

## Skip scan range

References:

- https://dev.mysql.com/doc/refman/8.0/en/range-optimization.html
- https://blog.jcole.us/2013/01/10/btree-index-structures-in-innodb
- http://mlwiki.org/index.php/B-Tree#Range_Lookups

Summary: for each distinct f1 value, perform a subrange scan (f1, {f2_condition})

Load `skip_scan_range.sql`.

Show the base explain:

```sh
EXPLAIN SELECT f1, f2 FROM ssr WHERE f2 > 40;
```

Then compare the costs without/with:

```sql
EXPLAIN FORMAT=JSON SELECT /*+ NO_SKIP_SCAN(ssr) */ f1, f2 FROM ssr WHERE f2 > 40\G
```

Explain two ways of comparing plans - `mylast` and Bash process substitution.

### Loose index scan (related subject, not 8.0)

Reference: https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html

Load `loose_index_scan.sql`.

Explain how to easily load random data:

- at the 3rd iteration: 176k (base = 4 records), 870k (base = 5 record)
- `@UPPER_BOUND * RAND()`, for integers;
- `HEX(RANDOM_BYTES(@CHAR_PAIRS))`, for (hex) strings (one pair is the minimum).

Compare the results without/with optimization:

```sql
EXPLAIN FORMAT=JSON SELECT /*+ NO_RANGE_OPTIMIZATION(lis) */ f1, MIN(f2) FROM lis GROUP BY f1\G
```

## Hash join

Sources:

- https://dev.mysql.com/worklog/task/?id=2241#tabs-2241-4
- https://www.percona.com/blog/2019/10/30/understanding-hash-joins-in-mysql-8

Internally, MySQL builds an in-memory hash table from a chosen "build" table, then iterates the other, "probe" table.

If the build table doesn't fit in memory, then smaller (build) ones are created, and for each, one full probe scanning is performed.

Clarify the conditionals: *all* tables must be equijoins, no LEFT/RIGHT joins.

Load `hash_join.sql`.

```sql
EXPLAIN FORMAT=TREE SELECT COUNT(*) FROM hj1 JOIN hj2 USING (c1)\G
-- -> Aggregate: count(0)
--     -> Inner hash join (hj2.c1 = hj1.c1)  (cost=3138584750.70 rows=3138566607)
--         -> Table scan on hj2  (cost=0.01 rows=177160)
--         -> Hash
--             -> Table scan on hj1  (cost=17804.25 rows=177160)
```

Filed bug about other EXPLAIN formats not showing the correct strategy (was duplicate).

- Fun fact: [PHP method names hashing](https://www.i-programmer.info/news/98-languages/6758-the-reason-for-the-weird-php-function-names.html).

### Issues with EXPLAIN

Hash join plans currently show only in `EXPLAIN FORMAT=TREE`.

Both in the standard and JSON format, they show as BLock Nested loop:

```sql
EXPLAIN SELECT COUNT(*) FROM hj1 JOIN hj2 USING (f1);

EXPLAIN FORMAT=JSON SELECT COUNT(*) FROM hj1 JOIN hj2 USING (f1)\G
```

## `information_schema_stats_expiry`

Reference: https://dev.mysql.com/doc/refman/8.0/en/statistics-table.html

```sql
CREATE TABLE ainc (id INT AUTO_INCREMENT PRIMARY KEY);

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';
-- +------------+----------------+
-- | TABLE_NAME | AUTO_INCREMENT |
-- +------------+----------------+
-- | ainc       |           NULL |
-- +------------+----------------+

INSERT INTO ainc VALUES (1);

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';
-- +------------+----------------+
-- | TABLE_NAME | AUTO_INCREMENT |
-- +------------+----------------+
-- | ainc       |           NULL |
-- +------------+----------------+

ANALYZE TABLE ainc;

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';
-- +------------+----------------+
-- | TABLE_NAME | AUTO_INCREMENT |
-- +------------+----------------+
-- | ainc       |              2 |
-- +------------+----------------+
```

## `innodb_flush_neighbors`

> When the table data is stored on a traditional HDD storage device, flushing such neighbor pages in one operation reduces I/O overhead (primarily for disk seek operations) compared to flushing individual pages at different times
> [...] buffer pool flushing is performed by page cleaner threads

## `innodb_max_dirty_pages_pct_lwm`, `innodb_max_dirty_pages_pct`

> Buffer pool flushing is initiated when the percentage of dirty pages reaches the low water mark value defined by the `innodb_max_dirty_pages_pct_lwm` variable. The default low water mark is 10% of buffer pool pages.
> The purpose of the `innodb_max_dirty_pages_pct_lwm` threshold is to control the percentage dirty pages in the buffer pool, and to prevent the amount of dirty pages from reaching the threshold defined by the `innodb_max_dirty_pages_pct` variable, which has a default value of 90. InnoDB aggressively flushes buffer pool pages if the percentage of dirty pages in the buffer pool reaches the innodb_max_dirty_pages_pct threshold.

Previous values: respectively, 10 and 75.

## GROUP BY is now unsorted (not implicitly sorted)

### SQL overview

- Reference: https://mysqlserverteam.com/removal-of-implicit-and-explicit-sorting-for-group-by

Load `groupby_unsorted.sql`.

Run on MySQL 5.7 and 8.0, and compare:

```sql
EXPLAIN FORMAT=JSON SELECT f1, SUM(f2) FROM gbu GROUP BY f1\G
```

The sort cost is (estimated) to be a very large part of the query!

Remember that cost is relative.

### Searching `GROUP BY`s without `ORDER` in the codebase

Load `groupby_codebase_search.sh`.

```sh
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
perl -MEnglish -lne 'print $ARGV if $previous =~ /GROUP BY/ && !/ORDER BY/; $previous = $ARG' /tmp/test* | xargs code
```

## TempTable engine

> [...] the TempTable storage engine, which is the default storage engine for in-memory internal temporary tables in MySQL 8.0, supports binary large object types as of MySQL 8.0.13. See Internal Temporary Table Storage Engine.
> The TempTable storage engine provides efficient storage for VARCHAR and VARBINARY columns.

5.7 was:

> Some query conditions prevent the use of an in-memory temporary table, in which case the server uses an on-disk table instead: Presence of a BLOB or TEXT column in the table.
> In-memory temporary tables are managed by the MEMORY storage engine, which uses fixed-length row format. VARCHAR and VARBINARY column values are padded to the maximum column length, in effect storing them as CHAR and BINARY columns.

Load `temptables.sql`.

Demonstration of the point, on MySQL 5.7:

```sql
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

## Schema migration tool issues

There's a known [showstopper bug](https://github.com/github/gh-ost/issues/687) on the latest Gh-ost release, which prevents operations from succeeding on MySQL 8.

Use `pt-online-schema-change` v3.0.x (but v3.1.0 is broken!) or Facebook's OnlineSchemaChange.

## Questions time

## Extra topics

### Turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments

### Negative regex (for GROUP BY)

Reference: https://stackoverflow.com/a/406408

```sh
grep -zP 'GROUP BY .+\n((?!ORDER BY ).)*\n' /tmp/test*
```

## Secondary/discarded topics

### Debate about doublewrite (read sources)

### Query caching is gone!

In a nutshell, query caching can be expensive to maintain in highly concurrent contexts, and even more so, cause contention.

References:

- https://mysqlserverteam.com/mysql-8-0-retiring-support-for-the-query-cache
- https://www.percona.com/blog/2015/01/02/the-mysql-query-cache-how-it-works-and-workload-impacts-both-good-and-bad
- http://www.markleith.co.uk/2010/09/24/tracking-mutex-locks-in-a-process-list-mysql-55s-performance_schema

- OPTIONAL/STUDY: how to analyze query caching savings in a running system with MySQL 5.7 (at a minimum, examine the query used for checking contention)

### In-depth review of VARCHARs/BLOBs

- OPTIONAL/STUDY (3 articles): general considerations about VARCHARs/BLOBs
  - [Live view char values storage fragmentation](https://dba.stackexchange.com/a/210430)
  - https://mysqlserverteam.com/externally-stored-fields-in-innodb
