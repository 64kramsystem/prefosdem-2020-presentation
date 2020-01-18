---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

- [Presentation Legenda/General dos/Personal notes](#presentation-legendageneral-dospersonal-notes)
- [Introduction](#introduction)
- [Preset MySQL configuration, and general tooling introduction](#preset-mysql-configuration-and-general-tooling-introduction)
- [Differences](#differences)
  - [Curiosity: innodb_data_file_path](#curiosity-innodbdatafilepath)
  - [First step before upgrading: output and compare the global system variables](#first-step-before-upgrading-output-and-compare-the-global-system-variables)
  - [SQL mode: `NO_AUTO_CREATE_USER`](#sql-mode-noautocreateuser)
  - [Optimizer switches: `use_invisible_indexes=off`](#optimizer-switches-useinvisibleindexesoff)
  - [Optimizer switches: `skip_scan=on` (Skip scan range optimization)](#optimizer-switches-skipscanon-skip-scan-range-optimization)
    - [Loose index scan (OPTIONAL)](#loose-index-scan-optional)
  - [Optimizer switches: `hash_join=on`](#optimizer-switches-hashjoinon)
  - [`information_schema_stats_expiry`](#informationschemastatsexpiry)
  - [`innodb_flush_neighbors`](#innodbflushneighbors)
  - [`innodb_max_dirty_pages_pct_lwm`, `innodb_max_dirty_pages_pct`](#innodbmaxdirtypagespctlwm-innodbmaxdirtypagespct)
  - [`innodb_stats_sample_pages`](#innodbstatssamplepages)
  - [Query caching is gone!](#query-caching-is-gone)
  - [GROUP BY not ordered by default anymore](#group-by-not-ordered-by-default-anymore)
  - [utf8mb4](#utf8mb4)
    - [Different collation](#different-collation)
    - [Columns/indexes now have less chars available](#columnsindexes-now-have-less-chars-available)
  - [TempTable engine](#temptable-engine)
  - [Gh-ost currently doesn't work!](#gh-ost-currently-doesnt-work)
- [Shortcomings in MySQL 8](#shortcomings-in-mysql-8)
  - [mysqldump not accepting patterns/mysqlpump broken](#mysqldump-not-accepting-patternsmysqlpump-broken)
  - [FT index administration problems on mysql](#ft-index-administration-problems-on-mysql)

## Presentation Legenda/General dos/Personal notes

| Label | Explanation |
| ---- | ---- |
| `WRITE` | section to write (or generic thing to do) |
| `STUDY` | subject to study and write|
| `EXPLAIN` | subject to bring up |
| `OPTIONAL` | subject to potentially bring up |

- OPTIONAL/STUDY: [MySQL LRU](https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool.html)

- Change buffer: buffer for secondary index changes, which can potentially be merged at a later time
- Undo tablespaces (logs): information about how to rollback changes made by a transaction
  - self-standing in mysql 8.0
- Data dictionary: in mysql 8.0, stored in the MySQL data dictionary

## Introduction

WRITE: introduction

## Preset MySQL configuration, and general tooling introduction

```sh
# Configuration

cat > ~/.my.cnf << CONF
[mysqld]

datadir                   = /home/saverio/databases/mysql_data
innodb_log_group_home_dir = /dev/shm/mysql_logs

# For compatibility with MySQL 5.7
lc_messages_dir           = /home/saverio/local/mysql/share
character_set_server      = utf8mb4

[client]

user = root

[mysql]

database = temp
CONF

which mystart
which mystop
```

EXPLAIN: automatic database

## Differences

### Curiosity: innodb_data_file_path

In MySQL 8.0, the system tablespace can be placed anywhere! Example:

```
datadir                   = /home/saverio/databases/mysql_data
innodb_data_home_dir      = /home/saverio/databases/innodb_data/
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend			# Won't work on v5.7, because it's an absolute path
```

In real world, one could/would  place the system tablespace and the redo log in the same (separate) disk. In such case, the configuration would be more like:

```
datadir                   = /home/saverio/databases/mysql_data
innodb_log_group_home_dir = /dev/shm/mysql_logs
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend
```

Filed bug about documentation!

- OPTIONAL: how to turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments
- OPTIONAL/STUDY: debate about doublewrite (read sources)

### First step before upgrading: output and compare the global system variables

EXPLAIN: general idea: get a nice, ordered table

```sh
cd ~/local

ln -sfn mysql-5* mysql # then show

mystart

# EXPLAIN: why `-t`
# EXPLAIN: long ones - we need to filter
mysql -te 'SHOW GLOBAL VARIABLES' | vim -

# EXPLAIN: SHOW ... WHERE
# EXPLAIN: RLIKE!
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name     RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.longs.5.7.txt
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/config.shorts.5.7.txt

mystop

ln -sfn mysql-8* mysql

mystart

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
CREATE TABLE t1 (f1 INT NOT NULL, f2 INT NOT NULL, PRIMARY KEY(f1, f2));

INSERT INTO t1 VALUES (1,1), (1,2), (1,3), (1,4), (1,5), (2,1), (2,2), (2,3), (2,4), (2,5);
INSERT INTO t1 SELECT f1, f2 + 5 FROM t1;
INSERT INTO t1 SELECT f1, f2 + 10 FROM t1;
INSERT INTO t1 SELECT f1, f2 + 20 FROM t1;
INSERT INTO t1 SELECT f1, f2 + 40 FROM t1;

ANALYZE TABLE t1;
```

Comparison!:

```sh
meld <(mysql -e "EXPLAIN FORMAT=JSON SELECT /*+ NO_SKIP_SCAN(t1) */ f1, f2 FROM t1 WHERE f2 > 40\G") \
     <(mysql -e "EXPLAIN FORMAT=JSON SELECT                         f1, f2 FROM t1 WHERE f2 > 40\G")
```

Filed bug about TEMPORARY tables!

#### Loose index scan (OPTIONAL)

- OPTIONAL/WRITE: Loose index scan (https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html): copy base data

### Optimizer switches: `hash_join=on`

- STUDY: hash joins instead of block nested loop

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

### Query caching is gone!

STUDY: https://mysqlserverteam.com/mysql-8-0-retiring-support-for-the-query-cache

### GROUP BY not ordered by default anymore

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

STUDY: review article

#### Different collation

STUDY: test on mac -> client with utf8 compiled (collation can't be specified)
STUDY: (review article) trailing space due to new collation

#### Columns/indexes now have less chars available

STUDY: find query for at-risk indexes

- OPTIONAL/STUDY (3 articles): general considerations about VARCHARs/BLOBs
  - https://dev.mysql.com/doc/refman/8.0/en/char.html
  - [Live view char values storage fragmentation](https://dba.stackexchange.com/a/210430)
  - https://mysqlserverteam.com/externally-stored-fields-in-innodb

> InnoDB encodes fixed-length fields greater than or equal to 768 bytes in length as variable-length fields, which can be stored off-page

### TempTable engine

> [...] the TempTable storage engine, which is the default storage engine for in-memory internal temporary tables in MySQL 8.0, supports binary large object types as of MySQL 8.0.13. See Internal Temporary Table Storage Engine.
> The TempTable storage engine provides efficient storage for VARCHAR and VARBINARY columns.

5.7 was:

> Some query conditions prevent the use of an in-memory temporary table, in which case the server uses an on-disk table instead: Presence of a BLOB or TEXT column in the table.
> In-memory temporary tables are managed by the MEMORY storage engine, which uses fixed-length row format. VARCHAR and VARBINARY column values are padded to the maximum column length, in effect storing them as CHAR and BINARY columns.

### Gh-ost currently doesn't work!

Use `pt-online-schema-change` (v3.1.0 is broken!)

## Shortcomings in MySQL 8

### mysqldump not accepting patterns/mysqlpump broken

OPTIONAL/WRITE: mysqldump not accepting patterns/mysqlpump broken

EXPLAIN: `--innodb-optimize-keys`

### FT index administration problems on mysql

OPTIONAL/STUDY: FT index administration problems on mysql
