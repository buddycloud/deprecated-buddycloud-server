var step = require('step');

/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

var FEATURES = {
    'create-nodes': {
	create: {
	    needOwner: true,
	    transaction: function(req, t, cb) {
		step(function() {
			 t.createNode(req.node, this);
		     }, function(err) {
			 if (err) throw err;

			 t.addOwner(req.from, req.node, this);
		     }, function(err) {
			 if (err) throw err;

			 t.subscribeNode(req.from, req.node, this);
		     }, cb);
	    }
	}
    },
    subscribe: {
	subscribe: {
	    transaction: function(req, t, cb) {
		t.subscribeNode(req.from, req.node, cb);
	    }
	}
    },
    publish: {
	publish: {
	    /* TODO: check perms */
	    transaction: function(req, t, cb) {
		var subscribers;

		step(function() {
			 if (!req.items)
			     this(null, []);
			 else {
			     var g = this.group();
			     for(var id in req.items) {
				 if (req.items.hasOwnProperty(id))
				     t.writeItem(req.from, req.node, id, req.items[id], g());
			     }
			 }
		     }, cb);
	    },
	    subscriberNotification: function(req, subscribers) {
		subscribers.forEach(function(subscriber) {
		    callFrontend('notify', subscriber, req.node, req.items);
		});
	    }
	}
    },
    'retract-items': {
	retract: {
	    transaction: function(req, t, cb) {
		var subscribers;

		/* TODO: check perms */
		step(function() {
			 if (req.itemIds.length < 1)
			     this(null, []);
			 else {
			     var g = this.group();
			     req.itemIds.forEach(function(itemId) {
				 t.deleteItem(req.node, itemId, g());
			     });
			 }
		     }, cb);
	    },
	    subscriberNotification: function(req, subscribers) {
		subscribers.forEach(function(subscriber) {
		    callFrontend('retracted', subscriber, req.node, req.itemIds);
		});
	    }
	}
    },
    'retrieve-items': {
	retrieve: {
	    transaction: function(req, t, cb) {
		var ids, items;
		step(function() {
			 t.getItemIds(req.node, this);
		     }, function(err, ids_) {
			 if (err) throw err;

console.log("item ids: " + JSON.stringify(ids_));
			 ids = ids_;
			 if (ids.length < 1)
			     this(null, []);
			 else {
			     var g = this.group();
			     ids.forEach(function(id) {
				 t.getItem(req.node, id, g());
			     });
			 }
		     }, function(err, items) {
			 if (err) throw err;

			 /* Assemble ids & items lists into result dictionary */
			 var result = {};
			 var id, item;
			 while((id = ids.shift()) && (item = items.shift())) {
			     result[id] = item;
			 }
			 this(null, result);
		     }, cb);
	    }
	}
    },
    'retrieve-subscriptions': {
	retrieve: {
	    transaction: function(req, t, cb) {
		t.getSubscriptions(req.from, cb);
	    }
	}
    },
    'retrieve-affiliations': {
	retrieve: {
	    transaction: function(req, t, cb) {
		t.getAffiliations(req.from, cb);
	    }
	}
    },
    'manage-subscriptions': {
	retrieve: {
	    needOwner: true,  /* TODO: actually, only publisher required */
	    transaction: function(req, t, cb) {
		t.getAffiliations(req.node, cb);
	    }
	}
    }
};

exports.request = function(req) {
    var feature = FEATURES[req.feature];
    var operation = feature && feature[req.operation];

    if (!operation) {
	req.callback(new Error('not-implemented'));
	return;
    }
    var debug = function(s) {
	console.log(req.from + ' >> ' + req.feature + '/' + req.operation + ': ' + s);
    };

    if (operation.needOwner) {
	/* If ownership were not hard-coded anymore this had to be
	 * moved inside the transaction.
	 */
	var nodeM = req.node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/_\-]+)$/);
	var userM = req.from.match(/^(.+?):(.+)$/);
	if (!nodeM || nodeM[1] !== userM[2]) {
	    req.callback(new Error('forbidden'));
	    return;
	}
    }

    model.transaction(function(err, t) {
	if (err) {
	    req.callback(err);
	    return;
	}

	var transactionResults;
	/* Run operation transaction first */
	var steps = [function() {
			 debug('transaction');
			 operation.transaction(req, t, this);
		     }, function(err) {
			 debug('transaction done');
			 if (err) throw err;

			 /* Regardless of the following steps, we pass
			  * the operation's transaction result to the
			  * final callback.
			  */
			 transactionResults = arguments;
			 /* And continue:
			  */
			 this(null);
		     }];
        var subscribers;
	if (operation.subscriberNotification) {
	    /* For subscriber notification, get the list of subscribers
	     * while still inside transaction.
	     */
	    steps.push(function(err) {
		if (err) throw err;

		t.getSubscribers(req.node, this);
	    }, function(err, subscribers_) {
		if (err) throw err;

		subscribers = subscribers_;
		this(null);
	    });
	}
	/* Finalize transaction
	 */
	steps.push(function(err) {
	    if (err) {
		var that = this;
		debug('transaction rollback');
		t.rollback(function() {
		    /* Keep error despite successful rollback */
		    that(err);
		});
	    } else {
		debug('transaction commit');
		t.commit(this);
	    }
	});
	if (operation.subscriberNotification) {
	    /* Transaction successful? Call subscriberNotification. */
	    steps.push(function(err) {
		if (err) throw err;

		operation.subscriberNotification(req, subscribers);
		this(null);
	    });
	}
	/* Last step: return to caller (view) */
	steps.push(function(err) {
	    debug('callback');
	    if (err)
		req.callback(err);
	    else
		req.callback.apply(req, transactionResults);
	});

	step.apply(null, steps);
    });
};

var frontends = {};
/**
 * Hook frontend for uri prefix
 */
exports.hookFrontend = function(proto, hooks) {
    frontends[proto] = hooks;
};

/**
 * Call named hook by uri prefix
 */
function callFrontend(hook, uri) {
    var colonPos = uri.indexOf(':');
    if (colonPos > 0) {
	var proto = uri.substr(0, colonPos);
	uri = uri.substr(colonPos + 1);
    } else
	return;

    var args = Array.prototype.slice.call(arguments, 1);
    var frontend = frontends.hasOwnProperty(proto) && frontends[proto];
    var hookFun = frontend && frontend.hasOwnProperty(hook) && frontend[hook];
console.log({callFrontend:arguments,frontent:frontend,hookFun:hookFun,args:args});

    if (hookFun) {
	return hookFun.apply(frontend, args);
    }
};
