#!/bin/bash

basedir=$(dirname $0)/..

dbuser="buddycloud-server-test"
[[ "$TRAVIS" == "true" ]] && dbuser="postgres"

psql -U postgres &>/dev/null <<EOF
DROP DATABASE IF EXISTS "buddycloud-server-test";
CREATE DATABASE "buddycloud-server-test"
       OWNER "$dbuser"
       TEMPLATE template0
       ENCODING 'UTF-8';
EOF

psql -U $dbuser -d buddycloud-server-test -f $basedir/postgres/install.sql &>/dev/null
for sql in $basedir/postgres/upgrade-*.sql; do
    psql -U $dbuser -d buddycloud-server-test -f $sql &>/dev/null
done

psql -U $dbuser -d buddycloud-server-test -f $basedir/test/test_functions.sql &>/dev/null
psql -U $dbuser -d buddycloud-server-test -f $basedir/test/test_data.sql &>/dev/null
