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
