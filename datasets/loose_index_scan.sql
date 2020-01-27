CREATE TABLE lis (f1 INT, f2 INT, KEY (f1, f2));

INSERT INTO lis VALUES (1, 1), (2, 1), (2, 1), (3, 1);
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;
INSERT INTO lis SELECT RAND() * 5, RAND() * 16 FROM lis `a` JOIN lis `b`;

ANALYZE TABLE lis;
