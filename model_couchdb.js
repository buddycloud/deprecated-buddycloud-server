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

Transaction.prototype.createNode = function(owner, node, cb) {
    /* TODO: filter node for chars */
    db.save(encodeURIComponent(node), { }, cb);
};

Transaction.prototype.subscribeNode = function(subscriber, node, cb) {
    db.get(encodeURIComponent(node), function(err, res) {
	var doc = res && res.toJSON();
	if (err)
	    cb(err);
	else if (!doc) {
	    cb(new Error('not-found'));
	} else {
console.log({before:JSON.stringify(doc)});
	    if (!doc.hasOwnProperty('subscribers'))
		doc.subscribers = [];
	    doc.subscribers.push(subscriber);
console.log({after:JSON.stringify(doc)});
	    db.save(encodeURIComponent(node), doc._rev, doc, cb);
	}
    });
};

Transaction.prototype.publishItems = function(publisher, node, items, cb) {
    var docs = [];
    for(var id in items) {
	if (items.hasOwnProperty(id))
	    docs.push({ _id: node + '/' + id,
			xml: items[id].toString() });
    }
    db.save(docs, cb);
};

Transaction.prototype.commit = function(cb) {
    cb(null);
};
