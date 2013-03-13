PostgreSQL schema
=================

Installation instructions
-------------------------

When installing the server, you must first execute `install.sql`, then all the
upgrade files in order, i.e. first `upgrade-1.sql`, then `upgrade-2.sql`, etc.:

    # switch to the postgres user
    sudo su - postgres
 
    # create the database user and assign them a password
    createuser buddycloud_server --pwprompt --no-superuser --no-createdb --no-createrole
 
    # create the database
    createdb --owner buddycloud_server --encoding UTF8 buddycloud_server
    
    # install the schema files
    psql -U buddycloud_server -d buddycloud_server < install.sql
    psql -U buddycloud_server -d buddycloud_server < upgrade-1.sql
    
    # Test the database is installed
    psql -h 127.0.0.1 --username buddycloud_server -d buddycloud_server -c "select * from nodes;"
    Password for user buddycloud_server: 
    node
    ------
    (0 rows) #  0 or more rows means that your buddycloud server database schema been installed successfully.


Upgrade instructions
--------------------

If you need to upgrade the schema version after upgrading the server software,
you'll need to be a little more careful.

First, stop the server and **back up your DB**. The simplest way to do this is
to run `pg_dump -c -U <username> <db> > backup.sql`.

Then, read the version notes below: they will tell you what you need to take
care of.

Once done you can apply the files needed for your upgrade: if your DB schema is
currently version 3 and you need version 5, you will apply `upgrade-4.sql` and
`upgrade-5.sql` but not `upgrade-3.sql` and below.


Version notes
=============

`upgrade-1.sql`
---------------

* This version adds a column and an index to the `items` table. This can take a
  long time.
* **Anonymous users**: this will mark users looking like `*@anon.*` as anonymous
  users that can be removed from the DB. So if someone on your server is
  following anyone with a JID similar to `*@anon.*`, you will need to remove the
  "anonymous" flag for these subscriptions (`UPDATE subscriptions SET
  anonymous=FALSE WHERE "user" LIKE '%@anon.ymo.us';`)
* **Buggy entries in `items` table**: a bug in sync caused subscription stanzas
  to be added to the `items` table (XML `<query ...></query>` and node ending
  with `/subscriptions`). They can (and should) be removed.
