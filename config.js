/**
 * XMPP Component connection
 */
exports.xmpp = { jid: 'irc.spaceboyz.net',
		 password: 'hastenichgesehn',
		 host: 'localhost',
		 port: 5348
	       };

/**
 * Enable & configure one of the following backends.
 */

// CouchDB backend
exports.modelBackend = 'couchdb';
exports.modelConfig = {
    host: 'localhost',
    port: 5984,
    database: 'channel-server'
};

/*
// PostgreSQL backend
exports.modelBackend = 'postgres';
exports.modelConfig = {
    host: 'localhost',
    port: 5432,
    database: 'channel-server',
    user: 'node',
    password: '***'
};
*/