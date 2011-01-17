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
			 var g = this.group();
			 for(var id in req.items) {
			     if (req.items.hasOwnProperty(id))
				 t.writeItem(req.from, req.node, id, req.items[id], g());
			 }
		     }, cb);
	    },
	    /* TODO: */
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
			 var g = this.group();
			 req.itemIds.forEach(function(itemId) {
			     t.deleteItem(req.node, itemId, g());
			 });
		     }, cb);
	    },
	    /* TODO: */
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

			 ids = ids_;
			 var g = this.group();
			 ids.forEach(function(id) {
					 t.getItem(req.node, id, g());
				     });
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

    if (operation.needOwner) {
	/* If ownership were not hard-coded anymore this had to be
	 * moved inside the transaction.
	 */
	var nodeM = req.node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/_\-]+)$/);
	var userM = req.from.match(/^(.+?):(.+)$/);
	if (!nodeM || nodeM[1] !== userM[2]) {
	    cb(new Error('forbidden'));
	    return;
	}
    }

    model.transaction(function(err, t) {
	if (err) {
	    req.callback(err);
	    return;
	}

	operation.transaction(req, t, function(err) {
	    if (err)
		t.rollback(requestFinalizer(req, arguments));
	    else
		t.commit(requestFinalizer(req, arguments));
	});
    });
};

function requestFinalizer(req, args) {
    return function() {
	req.callback.apply(req, args);
    };
}

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
