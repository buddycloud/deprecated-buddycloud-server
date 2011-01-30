CREATE TABLE nodes (node TEXT NOT NULL PRIMARY KEY,
       	     	    title TEXT,
		    access_model TEXT,
		    publish_model TEXT);
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

