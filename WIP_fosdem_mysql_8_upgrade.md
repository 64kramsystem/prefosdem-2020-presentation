---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

[TOC]

## Presentation Legenda/General dos/Personal notes

| Label | Explanation |
| ---- | ---- |
| `WRITE` | section to write (or generic thing to do) |
| `STUDY` | subject to study |
| `EXPLAIN` | subject to bring up |
| `OPTIONAL` | subject to potentially bring up |

- WRITEME: plan how to remember things to do without being in the slides, and how to know what's OPTIONAL for a given subject
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

- OPTIONAL: how to turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments
- OPTIONAL: debate about doublewrite (STUDY: read sources)

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

- STUDY/WRITE: invisible indexes

### Optimizer switches: `skip_scan=on`

- STUDY/WRITE: Skip scan range optimization (STUDY: https://dev.mysql.com/doc/refman/8.0/en/range-optimization.html)

- OPTIONAL/STUDY: Loose index scan (STUDY: https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html)
- OPTIONAL/STUDY: MySQL B-trees implementation

### Optimizer switches: `hash_join=on`

- STUDY/WRITE: hash joins instead of block nested loop

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

WRITE: using grep with regular expressions

### utf8mb4

STUDY/WRITE: review article

#### Different collation

STUDY/WRITE: test on mac -> client with utf8 compiled (collation can't be specified)
STUDY/WRITE: (review article) trailing space due to new collation

#### Columns/indexes now have less chars available

STUDY/WRITE: find query for at-risk indexes

- OPTIONAL/STUDY/WRITE (3 articles): general considerations about VARCHARs/BLOBs
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

WRITE

### mysqldump not accepting patterns/mysqlpump broken

WRITE

EXPLAIN: `--innodb-optimize-keys`

### FT index administration problems on mysql

WRITE
