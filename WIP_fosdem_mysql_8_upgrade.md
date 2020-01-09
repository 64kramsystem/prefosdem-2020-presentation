---
layout: post
title: WIP FOSDEM MySQL 8 Upgrade
tags: [databases,innodb,linux,mysql,shell_scripting,sysadmin]
---

See INTERESTING notes and TODO/STUDY.

TODO: introduction

TODO: how to introduce `--innodb-optimize-keys`?

TODO: read https://www.cfpland.com/guides/speaking

Contents (/WIP_fosdem_mysql_8_upgrade#):

## (Minimal) MySQL configuration

```
[mysqld]

tmpdir                    = /home/saverio/databases/mysql_temp
datadir                   = /home/saverio/databases/mysql_data
innodb_log_group_home_dir = /dev/shm/mysql_logs

# For compatibility with MySQL 5.7
lc_messages_dir = /home/saverio/local/mysql/share
character_set_server=utf8mb4

[client]

user = root

[mysql]

auto-rehash = FALSE
```

## Differences

### Curiosity: innodb_data_file_path

It seems that in MySQL 8.0, the system tablespace can be placed anywhere.

This doesn't work in MySQL 5.7:

```
innodb_log_group_home_dir = /dev/shm/mysql_logs
innodb_data_file_path     = /dev/shm/mysql_logs/ibdata1:12M:autoextend
```

as it raises an error:

```
2020-01-09T00:40:15.722916Z 0 [ERROR] InnoDB: File .//dev/shm/mysql_logs/ibdata1: 'create' returned OS error 71. Cannot continue operation
```

the [documentation](https://dev.mysql.com/doc/refman/8.0/en/innodb-init-startup-configuration.html) is not entirely clear:

> InnoDB forms the directory path for each data file by textually concatenating the value of innodb_data_home_dir to the data file name. If innodb_data_home_dir is not defined, the default value is “./”, which is the data directory.

as it should _not_ work on 8.0 as well (instead, it does).

INTERESTING:

- logs and innodb system tablespace (doublewrite buffer) in an NVRAM drive (or anyway, for development)

### General upgrade advice: always compare the status variables

- Use a very vanilla version of `~/.my.cnf`.

```sh

# make sure cnf is minimatl

cd ~/local

ln -sfn mysql-5* mysql # then show

mystart

mysql -te 'SHOW GLOBAL VARIABLES' > ~/Desktop/mysql_default_config.5.7.txt # show the unfiltered output

mysql -te 'SHOW GLOBAL VARIABLES LIKE "optimizer_switch|sql_mode"' > ~/Desktop/mysql_config.longs.5.7.txt
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/mysql_config.shorts.5.7.txt

mystop

ln -sfn mysql-8* mysql

mystart

mysql -te 'SHOW GLOBAL VARIABLES LIKE "optimizer_switch|sql_mode"' > ~/Desktop/mysql_config.longs.8.0.txt
mysql -te 'SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode"' > ~/Desktop/mysql_config.shorts.8.0.txt

meld ~/Desktop/mysql*longs*
meld ~/Desktop/mysql*shorts*

```

INTERESTING:

- SHOW ... WHERE
- RLIKE! (example with character set and collation)
- new: `information_schema_stats_expiry`
- MySQL 8.0 Invisible indexes (STUDY)
- Skip scan range optimization (STUDY: https://dev.mysql.com/doc/refman/8.0/en/range-optimization.html)
  - Loose index scan (STUDY: https://dev.mysql.com/doc/refman/8.0/en/group-by-optimization.html)
  - B-trees (STUDY)
- Query caching gone (STUDY)
- innodb_flush_neighbors
- TempTable (STUDY)
- innodb_max_dirty_pages_pct (STUDY/MAYBE)
- innodb_parallel_read_threads (STUDY/MAYBE)
- innodb_max_dirty_pages_pct (NO)

- STUDY: MySQL LRU (https://dev.mysql.com/doc/refman/5.5/en/innodb-buffer-pool.html)

### GROUP BY not ordered by default anymore

INTERESTING: using grep with regular expressions

### utf8mb4

STUDY: review article

#### utf8mb4: different collation

- TODO: test on mac -> client with utf8 compiled (collation can't be specified)
- STUDY (review article) trailing space due to new collation

#### utf8mb4: columns/indexes now have less chars available

- TODO: convenience of moving to BLOBs

### Stats are now cached (`information_schema_stats_expiry`)

### Gh-ost currently doesn't work!

## Shortcomings in MySQL 8

### mysqldump not accepting patterns/mysqlpump broken
