CREATE TABLE gbu (f1 INT, f2 INT);

INSERT INTO gbu VALUES (1, 1), (2, 2), (3, 3), (4, 4);
INSERT INTO gbu SELECT a.f1, a.f2 + 1 FROM gbu `a` JOIN gbu `b`;
INSERT INTO gbu SELECT a.f1, a.f2 + 10 FROM gbu `a` JOIN gbu `b`;
INSERT INTO gbu SELECT a.f1, a.f2 + 100 FROM gbu `a` JOIN gbu `b`;

ANALYZE TABLE gbu;
