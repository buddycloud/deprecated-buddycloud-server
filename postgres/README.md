PostgreSQL schema
=================

Installation instructions
-------------------------

When installing the server, you must first execute `install.sql`, then all the
upgrade files in order, i.e. first `upgrade-1.sql`, then `upgrade-2.sql`, etc.:

    psql -U <username> -d <db> < install.sql
    psql -U <username> -d <db> < upgrade-1.sql


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
