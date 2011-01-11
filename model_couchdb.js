/* TODO: remove 409 'conflict' retrying from cradle */
var cradle = require('cradle@0.3.1');
cradle.setup({host: '127.0.0.1',
	      port: 5984,
              cache: false, raw: false});
var db = new(cradle.Connection)().database('channel-server');

exports.transaction = function(cb) {
    new Transaction(cb);
};

function Transaction(cb) {
    this.transactionCb = cb;
    cb(null, this);
}

Transaction.prototype.commit = function(cb) {
    cb(null);
};


Transaction.prototype.createNode = function(owner, node, cb) {
    /* TODO: filter node for chars */
    db.save(encodeURIComponent(node), { }, function(err) {
	cb(err && new Error(err.error));
    });
};

Transaction.prototype.subscribeNode = function(subscriber, node, cb) {
    db.get(encodeURIComponent(node), function(err, res) {
	if (err) {
	    cb(new Error(err.error));
	    return;
	}

	var doc = res && res.toJSON();
	if (!doc) {
	    cb(new Error('not-found'));
	} else {
	    if (!doc.hasOwnProperty('subscribers'))
		doc.subscribers = [];
	    doc.subscribers.push(subscriber);
	    db.save(encodeURIComponent(node), doc._rev, doc, function(err) {
		if (err && err.error === 'conflict')
		    subscribeNode(subscriber, node, cb);
		else
		    cb(err && new Error(err.error));
	    });
	}
    });
};

Transaction.prototype.getSubscribers = function(node, cb) {
    db.get(encodeURIComponent(node), function(err, res) {
	if (err) {
	    cb(err && new Error(err.error));
	    return;
	}

	var doc = res && res.toJSON();
	cb(null, doc.subscribers || []);
    });
};

Transaction.prototype.writeItems = function(publisher, node, items, cb) {
    var docs = [];
    for(var id in items) {
	if (items.hasOwnProperty(id))
	    docs.push({ _id: encodeURIComponent(node) + '&' + encodeURIComponent(id),
			xml: items[id].toString() });
    }
    db.save(docs, function(err) {
	cb(err && new Error(err));
    });
};

