#!/bin/sh

basedir=$(dirname $0)/..

psql -U postgres &>/dev/null <<EOF
CREATE USER "buddycloud-server-test"
       PASSWORD 'tellnoone';
DROP DATABASE IF EXISTS "buddycloud-server-test";
CREATE DATABASE "buddycloud-server-test"
       OWNER "buddycloud-server-test"
       TEMPLATE template0
       ENCODING 'UTF-8';
EOF

psql -U buddycloud-server-test -d buddycloud-server-test -f $basedir/postgres/install.sql &>/dev/null
for sql in $basedir/postgres/upgrade-*.sql; do
    psql -U buddycloud-server-test -d buddycloud-server-test -f $sql &>/dev/null
done

psql -U buddycloud-server-test -d buddycloud-server-test -f $basedir/test/test_functions.sql &>/dev/null
psql -U buddycloud-server-test -d buddycloud-server-test -f $basedir/test/test_data.sql &>/dev/null
