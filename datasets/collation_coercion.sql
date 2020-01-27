CREATE TABLE tcolls (
  c3_gen CHAR(1) CHARACTER SET utf8mb3 COLLATE utf8mb3_general_ci,
  c4_gen CHAR(1) CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci,
  c4_900 CHAR(1) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci
);
INSERT INTO tcolls VALUES('ä', 'ä', 'ä');
