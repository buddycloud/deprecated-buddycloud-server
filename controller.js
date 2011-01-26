var step = require('step');
var errors = require('./errors');

/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

/**
 * Transactions with result data better callback with an Array, so we
 * can apply Result Set Management easily.
 */
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
	    needPublisher: true,
	    transaction: function(req, t, cb) {
		var subscribers;

		step(function() {
			 if (objectIsEmpty(req.items))
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
	    needPublisher: true,
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
	    withAffiliation: true,
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
	},
	modify: {
	    needOwner: true,
	    /* TODO: only let owner subscribe users who intended to */
	    transaction: function(req, t, cb) {
		step(function() {
			 if (objectIsEmpty(req.subscriptions)) {
			     this(null);
			     return;
			 }

			 var g = this.group();
			 for(var user in req.subscriptions) {
			     var subscription = req.subscriptions[user];
			     switch(subscription) {
			     case 'subscribed':
				     t.subscribeNode(user, req.node, g());
				     break;
			     case 'none':
				     t.unsubscribeNode(user, req.node, g());
				     break;
			     }
			 }
		     }, cb);
	    },
	    subscriberNotification: function(req, subscribers) {
		/* TODO */
	    }
	}
    },
    'modify-affiliations': {
	retrieve: {
	    needOwner: true,
	    /* TODO: outcast only if req.affiliation == 'owner' or 'publisher' */
	    transaction: function(req, t, cb) {
		t.getAffiliated(req.node, cb);
	    }
	},
	modify: {
	    needOwner: true,
	    transaction: function(req, t, cb) {
		if (objectIsEmpty(req.affiliations)) {
		    this(null);
		    return;
		}

		step(function() {
			 var g = this.group();
			 for(var user in req.affiliations) {
			     var affiliation = req.affiliations[user];
			     switch(affiliation) {
			     case 'owner':
				 t.addOwner(user, req.node, g());
				 /* TODO: deny dropping ownership */
				 break;
			     case 'publisher':
			     case 'member':
			     case 'none':
				 /* TODO */
				 g();
				 break;
			     }
			 }
		     }, cb);
	    }
	}
    },
    'config-node': {
	retrieve: {
	    needOwner: true,
	    transaction: function(req, t, cb) {
		t.getConfig(req.node, cb);
	    }
	},
	modify: {
	    needOwner: true,
	    transaction: function(req, t, cb) {
		t.setConfig(req.node, { title: req.title,
					accessModel: req.accessModel,
					publishModel: req.publishModel
				      }, cb);
	    }
	}
    }
};

exports.pubsubFeatures = function() {
    var result = [];
    for(var f in FEATURES)
	result.push(f);
    return result;
};

exports.request = function(req) {
    var feature = FEATURES[req.feature];
    var operation = feature && feature[req.operation];
    req.affiliation = 'none';

    if (!operation) {
	req.callback(new errors.FeatureNotImplemented('Operation not yet supported'));
	return;
    }
    var debug = function(s) {
	console.log(req.from + ' >> ' + req.feature + '/' + req.operation + ': ' + s);
    };

    /* TODO: no underscores */
    var nodeM = req.node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/_\-]+)$/);
    var userM = req.from.match(/^(.+?):(.+)$/);
    if (nodeM && nodeM[1] === userM[2])
	req.affiliation = 'owner';

    if (operation.needOwner && req.affiliation !== 'owner') {
	/* If ownership were not hard-coded anymore this had to be
	 * moved inside the transaction.
	 */
	req.callback(new errors.Forbidden('Ownership required'));
	return;
    }

    model.transaction(function(err, t) {
	if (err) {
	    req.callback(err);
	    return;
	}

	var steps = [function(err) {
			 /* Unfortunately, step starts with err = [] */
			 this(null);
		     }];

	/* Retrieve affiliation if needed */
	/* TODO: make level */
	if ((operation.withAffiliation || operation.needPublisher || operation.needMember) &&
	    req.affiliation === 'none') {
	    console.log('need affiliation...');
	    steps.push(function(err) {
		if (err) throw err;

		t.getAffiliation(req.from, req.node, this);
	    }, function(err, affiliation) {
		if (err) throw err;

		req.affiliation = affiliation;
		if (operation.needPublisher && affiliation === 'publisher')
		    this(null);
		else if (operation.needMember &&
			 (affiliation === 'publisher' || affiliation === 'member'))
		    this(null);
		else if (operation.needPublisher)
		    this(new errors.Forbidden('Publisher rights required'));
		else if (operation.needMember)
		    this(new errors.Forbidden('Membership required'));
		else
		    this(null);
	    });
	}

	/* Run operation transaction first */
	var transactionResults;
	steps.push(function(err) {
	    if (err) throw err;
	    debug('transaction');

	    operation.transaction(req, t, this);
	}, function(err) {
	    if (err) throw err;
	    debug('transaction done');

	    /* Regardless of the following steps, we pass
	     * the operation's transaction result to the
	     * final callback.
	     */
	    transactionResults = arguments;
	    /* And continue:
	     */
	    this(null);
	});
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
		debug('transaction rollback: ' + (err.message || JSON.stringify(err)));
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

exports.getAllSubscribers = function(cb) {
    model.transaction(function(err, t) {
	if (err) {
	    cb(err);
	    return;	    
	}

	t.getAllSubscribers(function(err, subscribers) {
	    if (err) {
		t.rollback(function() {
			       cb(err);
			   });
		return;
	    }

	    t.commit(function() {
		cb(null, subscribers);
	    });
	});
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


/* A helper */
function objectIsEmpty(o) {
    for(var k in o) {
	if (o.hasOwnProperty(k))
	    return false;
    }
    return true;
}
