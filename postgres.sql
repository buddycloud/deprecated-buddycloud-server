CREATE TABLE nodes (node TEXT NOT NULL PRIMARY KEY);
CREATE TABLE node_config (node TEXT NOT NULL REFERENCES nodes (node),
       	     		  "key" TEXT,
			  "value" TEXT,
			  updated TIMESTAMP,
			  PRIMARY KEY (node, "key"));
CREATE TABLE items (node TEXT REFERENCES nodes (node),
       	     	    id TEXT NOT NULL,
		    author TEXT,
		    updated TIMESTAMP,
		    xml TEXT,
		    PRIMARY KEY (node, id));
CREATE TABLE subscriptions (node TEXT REFERENCES nodes (node),
       	     		    "user" TEXT,
			    listener TEXT,
			    subscription TEXT,
 			    updated TIMESTAMP,
			    PRIMARY KEY (node, "user"));
CREATE TABLE affiliations (node TEXT REFERENCES nodes (node),
       	     		   "user" TEXT,
			   affiliation TEXT,
 			   updated TIMESTAMP,
			   PRIMARY KEY (node, "user"));

