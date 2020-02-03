- [Introduction: Who am I](#introduction-who-am-i)
- [Introduction: Presentation and target audience](#introduction-presentation-and-target-audience)
- [Preparing MySQL: setup and tooling](#preparing-mysql-setup-and-tooling)
- [Summary of the points requiring attention](#summary-of-the-points-requiring-attention)
- [Migrating to utf8mb4: Summary](#migrating-to-utf8mb4-summary)
  - [How the charset parameters work](#how-the-charset-parameters-work)
  - [Collation coercion, and issues `general` <> `0900_ai`](#collation-coercion-and-issues-general--0900_ai)
    - [Comparisons utf8_general_ci column <> literals](#comparisons-utf8_general_ci-column--literals)
    - [Comparisons utf8_general_ci column <> columns](#comparisons-utf8_general_ci-column--columns)
  - [Issues with `0900_ai` collation padding](#issues-with-0900_ai-collation-padding)
  - [Triggers](#triggers)
  - [Behavior with indexes](#behavior-with-indexes)
  - [Consequences of the increase in (potential) size of char columns](#consequences-of-the-increase-in-potential-size-of-char-columns)
- [`information_schema_stats_expiry` introduction](#information_schema_stats_expiry-introduction)
- [GROUP BY is now unsorted (not implicitly sorted)](#group-by-is-now-unsorted-not-implicitly-sorted)
- [Schema migration tool issues](#schema-migration-tool-issues)
- [Conclusion](#conclusion)
- [Extra: comparing the global system variables between major releases](#extra-comparing-the-global-system-variables-between-major-releases)
- [Extra: Mac Homebrew default collation is `utf8mb4_general_ci`!](#extra-mac-homebrew-default-collation-is-utf8mb4_general_ci)

## Introduction: Who am I

## Introduction: Presentation and target audience

The presentation shows the core problems to take care of - more advanced (eg. at scale) problems are not tackled, e.g. `innodb_max_dirty_pages_pct[_lwm]`.

## Preparing MySQL: setup and tooling

```sh
cd ~/local

# Amusing but excessive :-)
#
# ls -1 *.tar.* | tee $(tty) | parallel tar xvf

ls -l *.tar.*
ls -1 *.tar.* | parallel tar xvf

ln -sf ~/code/prefosdem-2020-presentation/files/my.cnf ~/.my.cnf

cat ~/.my.cnf
```

## Summary of the points requiring attention

[...]

## Migrating to utf8mb4: Summary

References

- https://mysqlserverteam.com/mysql-8-0-collations-the-devil-is-in-the-details
- http://mysqlserverteam.com/new-collations-in-mysql-8-0-0

Improvements of the collation - it's updated to Unicode 9.0, with a new collation.

Typical example - more correct accent insensitivity:

```sql
-- Å = U+212B
SELECT "sÅverio" = "saverio" COLLATE utf8mb4_general_ci;
-- +--------+
-- | result |
-- +--------+
-- |      0 |
-- +--------+

SELECT "sÅverio" = "saverio"; -- Default (COLLATE utf8mb4_0900_ai_ci);
-- +--------+
-- | result |
-- +--------+
-- |      1 |
-- +--------+
```

Explain history of the 0900 decision, and problems with web documentation.

### How the charset parameters work

```sql
SHOW VARIABLES WHERE Variable_name RLIKE '^(character_set|collation)_' AND Variable_name NOT RLIKE 'system|data|dir';
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

#### Comparisons utf8_general_ci column <> literals

Reference: https://dev.mysql.com/doc/refman/8.0/en/charset-collation-coercibility.html

Comparison vs BMP utf8mb4:

```sql
SELECT c3_gen = 'ä' `result` FROM tcolls;
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

Comparison vs SMP (supplementary multilingual plane) character (emoji), with explicit collation:

```sql
SELECT c3_gen = '🍕' COLLATE utf8mb4_0900_ai_ci `result` FROM tcolls;
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

Comparison vs BMP utf8mb4 supplementary plan character (emoji), with implicit collation:

```sql
SELECT c3_gen = _utf8mb4'🍕' `result` FROM tcolls;
```

Weird? This is because:

- column:           2
- literal implicit: 4

So MySQL tries to convert the second value, and fails!

> 0: An explicit COLLATE clause (not coercible at all)
> 1: The concatenation of two strings with different collations
> 2: The collation of a column or a stored routine parameter or local variable
> 3: A “system constant” (the string returned by functions such as USER() or VERSION())
> 4: The collation of a literal
> 5: The collation of a numeric or temporal value
> 6: NULL or an expression that is derived from NULL

This is a problem if an application is in the migration process, and allows characters outside the "Basic Multilingual Plane" ("BMP").

#### Comparisons utf8_general_ci column <> columns

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

Difference in behavior:

```sql
-- Simulated (close enough) MySQL 5.7
--
SELECT '' = _utf8' ' COLLATE utf8_general_ci;
-- +---------------------------------------+
-- | '' = _utf8' ' COLLATE utf8_general_ci |
-- +---------------------------------------+
-- |                                     1 |
-- +---------------------------------------+

-- Current (8.0):
--
SELECT '' = ' ';
-- +----------+
-- | '' = ' ' |
-- +----------+
-- |        0 |
-- +----------+
```

Ouch! Where does this behavior come from? Let's check the collation (**attention**: it's `SHOW COLLATION`, without `s`, and use the field name (`Collation`)).

```sql
SHOW COLLATION WHERE Collation RLIKE 'utf8mb4_general_ci|utf8mb4_0900_ai_ci';
-- +--------------------+---------+-----+---------+----------+---------+---------------+
-- | Collation          | Charset | Id  | Default | Compiled | Sortlen | Pad_attribute |
-- +--------------------+---------+-----+---------+----------+---------+---------------+
-- | utf8mb4_0900_ai_ci | utf8mb4 | 255 | Yes     | Yes      |       0 | NO PAD        |
-- | utf8mb4_general_ci | utf8mb4 |  45 |         | Yes      |       1 | PAD SPACE     |
-- +--------------------+---------+-----+---------+----------+---------+---------------+
```

The following are the formal rules from the SQL (2003) standard (section 8.2):

> 3) The comparison of two character strings is determined as follows:
>
> a) Let CS be the collation [...]
>
> b) <u>If the length in characters of X is not equal to the length in characters of Y, then the shorter string is
>    effectively replaced, for the purposes of comparison, with a copy of itself that has been extended to
>    the length of the longer string by concatenation on the right of one or more pad characters</u>, where the
>    pad character is chosen based on CS. <u>If CS has the NO PAD characteristic, then the pad character is
>    an implementation-dependent character</u> different from any character in the character set of X and Y
>    that collates less than any string under CS. Otherwise, the pad character is a space.

Conclusion: before migrating, data must be trimmed, and must be 100% sure that the app doesn't introduce new instances.

### Triggers

Triggers are fairly easy to handle (see next), as they can be dropped/rebuilt - just make sure to consider comparisons in the trigger body.

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

utf8mb4 characters will take 33% more, which must stay withing the InnoDB index limit, which is however (as of 8.0 default), high (3072 bytes).

There may be details, but the above is a high-level guideline.

Remember:

- `[VAR]CHAR(n)` refers to the number of characters; therefore, the maximum requirement is `4 * n` bytes
- `TEXT` fields refer to the number of bytes

## `information_schema_stats_expiry` introduction

Reference: https://dev.mysql.com/doc/refman/8.0/en/statistics-table.html

Load `information_schema_stats_expiry.sql`.

```sql
-- Necessary: loads the stats
--
SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';

INSERT INTO ainc VALUES ();

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';
-- +------------+----------------+
-- | TABLE_NAME | AUTO_INCREMENT |
-- +------------+----------------+
-- | ainc       |           NULL |
-- +------------+----------------+

SHOW CREATE TABLE ainc\G
-- CREATE TABLE `ainc` (
--   `id` int NOT NULL AUTO_INCREMENT,
--   PRIMARY KEY (`id`)
-- ) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

ANALYZE TABLE ainc;

SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.tables WHERE table_name = 'ainc';
-- +------------+----------------+
-- | TABLE_NAME | AUTO_INCREMENT |
-- +------------+----------------+
-- | ainc       |              2 |
-- +------------+----------------+

SHOW GLOBAL VARIABLES LIKE '%stat%exp%';
-- +---------------------------------+-------+
-- | Variable_name                   | Value |
-- +---------------------------------+-------+
-- | information_schema_stats_expiry | 86400 |
-- +---------------------------------+-------+
```

## GROUP BY is now unsorted (not implicitly sorted)

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

# Freaky version, with negative regex match
#
# Reference: https://stackoverflow.com/a/406408
#
grep -zP 'GROUP BY .+\n((?!ORDER BY ).)*\n' /tmp/test*
```

## Schema migration tool issues

There's a known [showstopper bug](https://github.com/github/gh-ost/issues/687) on the latest Gh-ost release, which prevents operations from succeeding on MySQL 8.

Use trigger-based tools, like `pt-online-schema-change` v3.1.1 or v3.0.x (but v3.1.0 is broken!) or Facebook's OnlineSchemaChange

## Conclusion

- Over the next weeks, I will expand this subject into a series of articles in my professional blog
- This presentation is hosted at github.com/saveriomiroddi/prefosdem-2020-presentation

## Extra: comparing the global system variables between major releases

The general idea is to get a nice, ordered layout for comparing.

Show that the output is not very readable:

```sql
SHOW GLOBAL VARIABLES;
```

The compare the below between 5.7 and 8.0:

```sql
SHOW GLOBAL VARIABLES WHERE Variable_name NOT RLIKE "optimizer_switch|sql_mode";
```

## Extra: Mac Homebrew default collation is `utf8mb4_general_ci`!

When MySQL is installed via Homebrew, the default collation is `utf8mb4_general_ci`.

**attention: don't forget to pass the filename**

```sh
cd ~/code/homebrew-core-dev/Formula

# Print relevant section:
#
perl -ne 'print if /args = / .. /\]/' mysql.rb
#    args = %W[
#      -DFORCE_INSOURCE_BUILD=1
#      -DCOMPILATION_COMMENT=Homebrew
#      -DDEFAULT_CHARSET=utf8mb4
#      -DDEFAULT_COLLATION=utf8mb4_general_ci
#      -DINSTALL_DOCDIR=share/doc/#{name}
#      -DINSTALL_INCLUDEDIR=include/mysql
#      -DINSTALL_INFODIR=share/info
#      -DINSTALL_MANDIR=share/man
#      -DINSTALL_MYSQLSHAREDIR=share/mysql
#      -DINSTALL_PLUGINDIR=lib/plugin
#      -DMYSQL_DATADIR=#{datadir}
#      -DSYSCONFDIR=#{etc}
#      -DWITH_BOOST=boost
#      -DWITH_EDITLINE=system
#      -DWITH_SSL=yes
#      -DWITH_PROTOBUF=system
#      -DWITH_UNIT_TESTS=OFF
#      -DENABLED_LOCAL_INFILE=1
#      -DWITH_INNODB_MEMCACHED=ON
#    ]

# Fix it!
#
perl -i -ne 'print unless /CHARSET|COLLATION/' mysql.rb

git diff
```

This will cause problems when connecting to an 8.0 server with standard defaults.

My fix PR has been merged into master.

There are two approaches.

1. Update the formula and rebuild MySQL:

```sh
formula_filename=$(brew formula mysql)

perl -i.bak -ne "print unless /CHARSET|COLLATION/" "$formula_filename"

brew reinstall --build-from-source mysql
```

2. Ignore the client encoding on handshake

Setting `character-set-client-handshake = OFF` in the MySQL configuration will impose on the clients the the default server character set.

```sh
# Show setting:
#
mysqld --verbose --help | grep handshake
```
