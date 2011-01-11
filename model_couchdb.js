var ltx = require('ltx');
/* TODO: remove 409 'conflict' retrying from cradle */
var cradle = require('cradle');
cradle.setup({host: '127.0.0.1',
	      port: 5984,
              cache: false, raw: false});
var db = new(cradle.Connection)().database('channel-server');

/**
 * Initialize views
 */
db.save('_design/channel-server',
	{ nodeItems: {
	      map: function(doc) {
		  var delim = doc._id.indexOf('&');
		  if (delim > 0) {
		      var node = doc._id.substr(0, delim);
		      var itemId = doc._id.substr(delim + 1);
		      emit(node, { id: itemId,
				   date: doc.date
				 });
		  }
	      },
	      reduce: function(key, values, rereduce) {
		  return values.sort(function(a, b) {
		      if (a.date < b.date)
			  return -1;
		      else if (a.date > b.date)
			  return 1;
		      else
			  return 0;
		  });
	      }
	  } });


/**
 * API entry point
 */
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

function nodeKey(node) {
    return encodeURIComponent(node);
}
function itemKey(node, item) {
    return encodeURIComponent(node) + '&' + encodeURIComponent(item);
}

Transaction.prototype.createNode = function(owner, node, cb) {
    /* TODO: filter node for chars */
    db.save(nodeKey(node), { }, function(err) {
	cb(err && new Error(err.error));
    });
};

Transaction.prototype.subscribeNode = function(subscriber, node, cb) {
    db.get(nodeKey(node), function(err, res) {
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
	    if (doc.subscribers.indexOf(subscriber) < 0)
		doc.subscribers.push(subscriber);
	    db.save(nodeKey(node), doc._rev, doc, function(err) {
		if (err && err.error === 'conflict')
		    subscribeNode(subscriber, node, cb);
		else
		    cb(err && new Error(err.error));
	    });
	}
    });
};

Transaction.prototype.getSubscribers = function(node, cb) {
    db.get(nodeKey(node), function(err, res) {
	if (err) {
	    cb(err && new Error(err.error));
	    return;
	}

	var doc = res && res.toJSON();
	cb(null, doc.subscribers || []);
    });
};

/**
 * An item is always the children array of the <item node='...'> element
 */
Transaction.prototype.writeItem = function(publisher, node, id, item, cb) {
    db.save(itemKey(node, id), { xml: item.join('').toString(),
				 date: new Date().toISOString()
			       }, function(err) {
	cb(err && new Error(err));
    });
};

Transaction.prototype.deleteItem = function(node, itemId, cb) {
    db.get(itemKey(node, itemId), function(err, doc) {
	if (err )
	    cb(err);
	else
	    db.remove(itemKey(node, itemId), doc._rev, cb);
    });
};

/**
 * sorted by time
 */
Transaction.prototype.getItemIds = function(node, cb) {
};

Transaction.prototype.getItem = function(node, id, cb) {
    db.get(itemKey(node, id), function(err, res) {
	if (err) {
	    cb(err && new Error(err.error));
	    return;
	}

	var item;
	try {
	    item = ltx.parse(res.toJSON().xml).children;
	} catch (e) {
	    item = [];
	}
	cb(null, item);

    });
};
