CREATE TABLE nodes (node TEXT NOT NULL PRIMARY KEY);
ALTER TABLE nodes OWNER TO "buddycloud-server";

CREATE TABLE node_config (node TEXT NOT NULL REFERENCES nodes (node),
       	     		  "key" TEXT,
			  "value" TEXT,
			  updated TIMESTAMP,
			  PRIMARY KEY (node, "key"));
ALTER TABLE node_config OWNER TO "buddycloud-server";

CREATE TABLE items (node TEXT REFERENCES nodes (node),
       	     	    id TEXT NOT NULL,
		    author TEXT,
		    updated TIMESTAMP,
		    xml TEXT,
		    PRIMARY KEY (node, id));
ALTER TABLE items OWNER TO "buddycloud-server";
CREATE INDEX items_updated ON items (updated);

CREATE TABLE subscriptions (node TEXT REFERENCES nodes (node),
       	     		    "user" TEXT,
			    listener TEXT,
			    subscription TEXT,
 			    updated TIMESTAMP,
			    PRIMARY KEY (node, "user"));
ALTER TABLE subscriptions OWNER TO "buddycloud-server";
CREATE INDEX subscriptions_updated ON subscriptions (updated);

CREATE TABLE affiliations (node TEXT REFERENCES nodes (node),
       	     		   "user" TEXT,
			   affiliation TEXT,
 			   updated TIMESTAMP,
			   PRIMARY KEY (node, "user"));
ALTER TABLE affiliations OWNER TO "buddycloud-server";
CREATE INDEX affiliations_updated ON affiliations (updated);

