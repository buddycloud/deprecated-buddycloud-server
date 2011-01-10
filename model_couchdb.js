var cradle = require('cradle');
cradle.setup({host: '127.0.0.1',
	      port: 5984,
              options: {cache: false, raw: false}});
var db = new(cradle.Connection)().database('channel-server');


exports.createNode = function(owner, node, cb) {
    /* TODO: filter node for chars */
    db.save(node, { }, cb);
};

exports.subscribeNode = function(subscriber, node, cb) {
    db.get(node, function(err, doc) {
	if (err)
	    cb(err);
	else if (!doc) {
	    cb(new Error('not-found'));
	} else {
	    doc = doc.json;
	    if (!doc.hasOwnProperty('subscribers'))
		doc.subscribers = []
	    doc.subscribers.push(subscriber);
console.log(JSON.stringify(doc));
	    db.save(node, doc._rev, doc, cb);
	}
    });
};

exports.publishItems = function(publisher, node, items, cb) {
    var docs = [];
    for(var id in items) {
	if (items.hasOwnProperty(id))
	    docs.push({ _id: node + '/' + id,
			xml: items[id].toString() });
    }
    db.save(docs, cb);
};
