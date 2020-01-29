CREATE TABLE ci3 (
  c3 CHAR(1) CHARACTER SET utf8,
  KEY (c3)
);

INSERT INTO ci3
VALUES ('a'), ('b'), ('c'), ('d'), ('e'), ('f'), ('g'), ('h'), ('i'), ('j'), ('k'), ('l'), ('m'),
       ('n'), ('o'), ('p'), ('q'), ('r'), ('s'), ('t'), ('u'), ('v'), ('w'), ('x'), ('y'), ('z');

CREATE TABLE ci4 (
  c4 CHAR(1) CHARACTER SET utf8mb4,
  KEY (c4)
);

INSERT INTO ci4 SELECT * FROM ci3;
