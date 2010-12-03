var persistence = require('persistencejs/persistence').persistence;


/**
 * Data Model
 */
exports.Node = persistence.define('Node', {
    node: "TEXT"
});
exports.Affiliation = persistence.define('Affiliation', {
    jid: "TEXT",
    affiliation: "TEXT"
});
exports.Node.hasMany('affiliations', exports.Affiliation, 'node');


/**
 * Backend
 */

var persistenceStore = require('persistencejs/persistence.store.mysql');
persistenceStore.config(persistence, 'localhost', 3306, 'channel', 'channel', 'channel');


/**
 * Connection Pool
 */
var persistencePool = require('persistencejs/persistence.pool');
var pool = new persistencePool.ConnectionPool(persistenceStore.getSession, 4);

/* Asynchronous, to limit # of sessions later (TODO) */
exports.getSession = function(cb) {
    cb(pool.obtain());
};

exports.getSession(function(session) {
    session.schemaSync();
});
