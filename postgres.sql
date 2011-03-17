CREATE TABLE nodes (node TEXT NOT NULL PRIMARY KEY);
CREATE TABLE node_config (node TEXT NOT NULL REFERENCES nodes (node),
       	     		  "key" TEXT,
			  "value" TEXT,
			  PRIMARY KEY (node, "key"));
CREATE TABLE items (node TEXT REFERENCES nodes (node),
       	     	    id TEXT NOT NULL,
		    published TIMESTAMP,
		    xml TEXT,
		    PRIMARY KEY (node, id));
CREATE TABLE subscriptions (node TEXT REFERENCES nodes (node),
       	     		    "user" TEXT,
			    subscription TEXT,
			    PRIMARY KEY (node, "user"));
CREATE TABLE affiliations (node TEXT REFERENCES nodes (node),
       	     		   "user" TEXT,
			   affiliation TEXT,
			   PRIMARY KEY (node, "user"));

