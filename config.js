/**
 * XMPP Component connection
 */
exports.xmpp = { jid: 'channels.example.com',
		 password: 'secret',
		 host: 'localhost',
		 port: 5233
	       };

/**
 * CouchDB backend
 */
exports.modelBackend = 'couchdb';
exports.modelConfig = {
    host: '127.0.0.1',
    port: 5984,
    database: 'channel-server'
};
