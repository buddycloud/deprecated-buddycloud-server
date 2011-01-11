var step = require('step');

/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

exports.createNode = function(owner, node, cb) {
    model.transaction(function(err, t) {
	t.createNode(owner, node, function(err) {
	    t.commit(cb);
	});
    });
};

/*
 * cb(affiliation, error)
 */
exports.subscribeNode = function(subscriber, node, cb) {
    model.transaction(function(err, t) {
	t.subscribeNode(subscriber, node, function(err) {
	    t.commit(cb);
	});
    });
};

exports.publishItems = function(publisher, node, items, cb) {
    model.transaction(function(err, t) {
	var subscribers;
	if (err) { cb(err); return; }

	step(function() {
	    var g = this.group();
	    for(var id in items) {
		if (items.hasOwnProperty(id))
		    t.writeItem(publisher, node, id, items[id], g());
	    }
	}, function(err) {
	    if (err) throw err;

	    t.getSubscribers(node, this);
	}, function(err, subscribers_) {
	    if (err) throw err;

	    subscribers = subscribers_;
	    t.commit(this);
	}, function(err) {
	    if (err) { cb(err); return; }

	    subscribers.forEach(function(subscriber) {
		callFrontend('notify', subscriber, node, items);
	    });
	    cb(null);
	});
    });
};

exports.retractItems = function(retracter, node, itemIds, notify, cb) {
    model.transaction(function(err, t) {
	var subscribers;

	step(function() {
	    var g = this.group();
	    itemIds.forEach(function(itemId) {
		t.deleteItem(node, itemId, g());
	    });
	}, function(err) {
	    if (err) throw err;

	    t.getSubscribers(node, this);
	}, function(err, subscribers_) {
	    if (err) throw err;

	    subscribers = subscribers_;
	    t.commit(this);
	}, function(err) {
	    if (err) { cb(err); return; }

	    if (notify) {
		subscribers.forEach(function(subscriber) {
		    callFrontend('retracted', subscriber, node, itemIds);
		});
	    }
	    cb(null);
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
