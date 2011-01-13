var step = require('step');

/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

exports.createNode = function(owner, node, cb) {
    var nodeM = node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/_\-]+)$/);
    var userM = owner.match(/^(.+?):(.+)$/);
    if (!nodeM || nodeM[1] !== userM[2]) {
	cb(new Error('forbidden'));
	return;
    }

    model.transaction(function(err, t) {
	step(function() {
	    t.createNode(node, this);
	}, function(err) {
	    if (err) throw err;

	    t.addOwner(owner, node, this);
	}, function(err) {
	    if (err) throw err;

	    t.subscribeNode(owner, node, this);
	}, function(err) {
	    if (err) throw err;

	    t.commit(this);
	}, cb);
    });
};

/*
 * 
 */
exports.subscribeNode = function(subscriber, node, cb) {
    model.transaction(function(err, t) {
	/* TODO: check node, check perms */
	t.subscribeNode(subscriber, node, function(err) {
	    t.commit(cb);
	});
    });
};

exports.publishItems = function(publisher, node, items, cb) {
    model.transaction(function(err, t) {
	var subscribers;
	if (err) { cb(err); return; }

	/* TODO: check perms */
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
	    if (err) throw err;

	    subscribers.forEach(function(subscriber) {
		callFrontend('notify', subscriber, node, items);
	    });
	    this(null);
	}, cb);
    });
};

exports.retractItems = function(retracter, node, itemIds, notify, cb) {
    model.transaction(function(err, t) {
	var subscribers;

	/* TODO: check perms */
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
	    if (err) throw err;

	    if (notify) {
		subscribers.forEach(function(subscriber) {
		    callFrontend('retracted', subscriber, node, itemIds);
		});
	    }
	    this(null);
	}, cb);
    });
};

exports.getItems = function(requester, node, cb) {
    model.transaction(function(err, t) {
	var ids, items;
	step(function() {
	    t.getItemIds(node, this);
	}, function(err, ids_) {
	    if (err) throw err;

	    ids = ids_;
	    var g = this.group();
	    ids.forEach(function(id) {
		t.getItem(node, id, g());
	    });
	}, function(err, items_) {
	    if (err) throw err;

	    items = items_;
	    t.commit(this);
	}, function(err) {
	    if (err) throw err;

	    /* Assemble ids & items lists into result dictionary */
	    var result = {};
	    var id, item;
	    while((id = ids.shift()) && (item = items.shift())) {
		result[id] = item;
	    }
	    this(null, result);
	}, cb);
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
