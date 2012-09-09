CREATE TABLE nodes (node TEXT NOT NULL PRIMARY KEY);
CREATE TABLE node_config (node TEXT NOT NULL REFERENCES nodes (node),
       	     		  "key" TEXT,
			  "value" TEXT,
			  updated TIMESTAMP,
			  PRIMARY KEY (node, "key"));
CREATE TABLE items (node TEXT REFERENCES nodes (node),
       	     	    id TEXT NOT NULL,
		    updated TIMESTAMP,
		    xml TEXT,
		    PRIMARY KEY (node, id));
CREATE INDEX items_updated ON items (updated);
CREATE TABLE subscriptions (node TEXT REFERENCES nodes (node),
       	     		    "user" TEXT,
			    listener TEXT,
			    subscription TEXT,
 			    updated TIMESTAMP,
			    PRIMARY KEY (node, "user"));
CREATE INDEX subscriptions_updated ON subscriptions (updated);
CREATE TABLE affiliations (node TEXT REFERENCES nodes (node),
       	     		   "user" TEXT,
			   affiliation TEXT,
 			   updated TIMESTAMP,
			   PRIMARY KEY (node, "user"));
CREATE INDEX affiliations_updated ON affiliations (updated);

CREATE VIEW open_nodes AS
       SELECT DISTINCT node FROM node_config
       	      WHERE "key"='accessModel'
	        AND "value"='open';
