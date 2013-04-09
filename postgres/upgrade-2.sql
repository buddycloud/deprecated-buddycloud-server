BEGIN TRANSACTION;

ALTER TABLE nodes
      ADD COLUMN federated BOOLEAN DEFAULT FALSE;

ALTER TABLE items
      ADD COLUMN federated BOOLEAN DEFAULT FALSE;

ALTER TABLE subscriptions
      ADD COLUMN federated BOOLEAN DEFAULT FALSE;

ALTER TABLE affiliations
      ADD COLUMN federated BOOLEAN DEFAULT FALSE;

INSERT INTO schema_version (version, "when", description)
       VALUES (2, 'now', 'Mark external items as such in the database');

COMMIT;
