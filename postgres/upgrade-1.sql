BEGIN TRANSACTION;

-- items: add an in-reply-to column
ALTER TABLE items
      ADD COLUMN in_reply_to TEXT;
UPDATE items
       SET in_reply_to = xmlserialize(content (
           xpath('//thr:in-reply-to/@ref', xmlparse(document "xml"),
                 ARRAY[ARRAY['thr', 'http://purl.org/syndication/thread/1.0']]
           ))[1] AS TEXT);
CREATE INDEX items_in_reply_to ON items (node, in_reply_to);

-- subscriptions: we need to know about temporary subscriptions
ALTER TABLE subscriptions
      ADD COLUMN "temporary" BOOLEAN DEFAULT FALSE;

-- remove subscriptions that look like anonymous users
DELETE FROM subscriptions WHERE "user" LIKE '%@anon.%';

-- we need a schema_version table!
CREATE TABLE schema_version (version INT NOT NULL PRIMARY KEY,
                             "when" TIMESTAMP,
                             description TEXT);
INSERT INTO schema_version (version, "when", description)
       VALUES (1, 'now', 'DB schema versioning, in-reply-to column, anonymous and temporary subscriptions');

COMMIT;
