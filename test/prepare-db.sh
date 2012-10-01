#!/bin/sh

psql -U postgres &>/dev/null <<EOF
CREATE USER "buddycloud-server-test"
       PASSWORD 'tellnoone';
DROP DATABASE IF EXISTS "buddycloud-server-test";
CREATE DATABASE "buddycloud-server-test"
       OWNER "buddycloud-server-test"
       TEMPLATE template0
       ENCODING 'UTF-8';
EOF

psql -U buddycloud-server-test -d buddycloud-server-test -f postgres/install.sql &>/dev/null
for sql in postgres/upgrade-*.sql; do
    psql -U buddycloud-server-test -d buddycloud-server-test -f $sql &>/dev/null
done
