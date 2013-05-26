BEGIN TRANSACTION;

-- Add cascading delete
ALTER TABLE items
DROP CONSTRAINT items_node_fkey,
ADD CONSTRAINT items_node_nodes_node
   FOREIGN KEY (node)
   REFERENCES nodes(node)
   ON DELETE CASCADE;

ALTER TABLE subscriptions
DROP CONSTRAINT subscriptions_node_fkey,
ADD CONSTRAINT subscriptions_node_nodes_node
   FOREIGN KEY (node)
   REFERENCES nodes(node)
   ON DELETE CASCADE;

ALTER TABLE affiliations
DROP CONSTRAINT affiliations_node_fkey,
ADD CONSTRAINT affiliations_node_nodes_node
   FOREIGN KEY (node)
   REFERENCES nodes(node)
   ON DELETE CASCADE;

ALTER TABLE node_config
DROP CONSTRAINT node_config_node_fkey,
ADD CONSTRAINT node_config_node_nodes_node
   FOREIGN KEY (node)
   REFERENCES nodes(node)
   ON DELETE CASCADE;

INSERT INTO schema_version (version, "when", description)
       VALUES (2, 'now', 'Cascading deletes from nodes table');

COMMIT;
