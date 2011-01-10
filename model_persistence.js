var persistence = require('persistencejs/persistence').persistence;


/**
 * Data Model
 */
exports.Node = persistence.define('Node', {
    node: "TEXT"
});
exports.Node.index('node');
exports.Affiliation = persistence.define('Affiliation', {
    jid: "TEXT",
    affiliation: "TEXT"
});
exports.Affiliation.index('jid');
exports.Node.hasMany('affiliations', exports.Affiliation, 'node');

exports.Item = persistence.define('Item', {
    itemId: "TEXT",
    body: "TEXT"
});
exports.Node.hasMany('items', exports.Item, 'node');


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

exports.createNode = function(node, owner, cb) {
    model.getSession(function(session) {
       session.transaction(function(tx) {
           model.Node.findBy(session, tx, "node", node, function(objs) {
               if (!objs) {
                   var nodeObj = new model.Node(session, { node: node });
                   nodeObj.affiliations.add(new model.Affiliation(session, { jid: owner,
                                                                             affiliation: 'owner'
                                                                           }));
                   session.add(nodeObj);
                   session.flush(tx, function() {
                       tx.commit(session, function() {
                           cb(null);
                       });
                   });
               } else {
                   tx.rollback(session, function() { });
                   cb(new Error('Node already exists'));
               }
           });
       });
    });
exports.subscribeNode = function(node, subscriber, cb) {
    model.getSession(function(session) {
       session.transaction(function(tx) {
           model.Affiliation.all(session).
                   filter("node", "=", node).
                   filter("jid", "=", subscriber).one(tx, function(obj) {
               if (!obj) {
                   var affiliationObj = new model.Affiliation(session, { jid: subscriber,
                                                                         affiliation: 'member' });
                   session.add(affiliationObj);
                   session.flush(tx, function() {
                       tx.commit(session, function() {
                           cb(null);
                       });
                   });
               } else {
                   tx.rollback(session, function() { });
                   cb(new Error('Node already exists'));
               }
           });
       });
    });

exports.writeItems = function(publisher, node, items) {
    model.getSession(function(session) {
       session.transaction(function(tx) {
           model.Item.all(session).
                   filter("")
