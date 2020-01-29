cat > /tmp/test1 << SQL
  GROUP BY col1
  -- ends here

  GROUP BY col2
  ORDER BY col2

  GROUP BY col3
  -- ends here

  GROUP BY col4
SQL

cat > /tmp/test2 << SQL

  GROUP BY col5
  ORDER BY col5
SQL
