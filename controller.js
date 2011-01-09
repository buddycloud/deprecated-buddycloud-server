/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

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
};

/*
 * cb(affiliation, error)
 */
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
};

exports.publishItems = function(publisher, node, items) {
    model.getSession(function(session) {
	session.transaction(function(tx) {
	    model.Item.all(session).
		    filter("")
};
