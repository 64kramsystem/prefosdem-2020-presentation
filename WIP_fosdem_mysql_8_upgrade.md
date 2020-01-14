---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

[TOC]

Labels:

- `WRITE`:             section to write
- `TODO`:               generic thing to do
- `STUDY`:             subject to study
- `EXPLAIN`:         subject to bring up
- `OPTIONAL`:      subject to potentially bring up

TODO: introduction

TODO: read https://www.cfpland.com/guides/speaking

## (Minimal) MySQL configuration

```sh
cat > ~/.my.cnf << CONF
[mysqld]

tmpdir                    = /home/saverio/databases/mysql_temp
datadir                   = /home/saverio/databases/mysql_data
innodb_log_group_home_dir = /dev/shm/mysql_logs

# For compatibility with MySQL 5.7
lc_messages_dir          = /home/saverio/local/mysql/share
character_set_server     = utf8mb4

[client]

user = root
CONF
```

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

EXPLAIN!
- explain how to turbocharge MySQL write capacity using an NVRAM device, or /dev/shm (tmpfs) in dev environments,

### General upgrade advice: always compare the status variables

EXPLAIN: general idea: get a nice, ordered table

```sh
mystop # for safety

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

EXPLAIN: `information_schema_stats_expiry`
EXPLAIN: `innodb_flush_neighbors`
EXPLAIN: Query caching gone (STUDY: https://mysqlserverteam.com/mysql-8-0-retiring-support-for-the-query-cache)
OPTIONAL: Skip scan range optimization (STUDY: https://dev.mysql.com/doc/refman/8.0/en/range-optimization.html)
  - Loose index scan (STUDY: https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html)
  - MySQL B-trees implementation (STUDY)
OPTIONAL: hash joins instead of block nested loop (STUDY)
OPTIONAL:  invisible indexes (study)
- innodb_max_dirty_pages_pct (STUDY/MAYBE)
- innodb_parallel_read_threads (OPTIONAL)
- innodb_max_dirty_pages_pct (NO)

- STUDY: MySQL LRU (https://dev.mysql.com/doc/refman/5.5/en/innodb-buffer-pool.html)

### GROUP BY not ordered by default anymore

EXPLAIN: using grep with regular expressions

### utf8mb4

STUDY: review article

#### different collation

WRITE
 - TODO: test on mac -> client with utf8 compiled (collation can't be specified)
 - STUDY (review article) trailing space due to new collation

v5.7 charset/collation defaults:
```
character_set_server=latin1
collation_server=latin1_swedish_ci
```

#### columns/indexes now have less chars available

TODO: find query for at-risk indexes

OPTIONAL: general considerations about VARCHARs/BLOBs
- STUDY: https://dev.mysql.com/doc/refman/8.0/en/char.html
> InnoDB encodes fixed-length fields greater than or equal to 768 bytes in length as variable-length fields, which can be stored off-page

- STUDY: https://dba.stackexchange.com/a/210430

- STUDY: https://mysqlserverteam.com/externally-stored-fields-in-innodb/



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
 - note `--innodb-optimize-keys`?

### FT index administration problems on mysql

WRITE

### Issue with joins not using indexes with few non-null values

MAYBE

## Personal notes

- change buffer: buffer for secondary index changes, which can potentially be merged at a later time
- undo tablespaces (logs): information about how to rollback changes made by a transaction
  - self-standing in mysql 8.0
- data dictionary: in mysql 8.0, stored in the MySQL data dictionary
