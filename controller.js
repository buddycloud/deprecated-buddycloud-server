var async = require('async');

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
	if (err) { cb(err); return; }

	t.writeItems(publisher, node, items, function(err) {
	    if (err) { cb(err); return; }

	    t.getSubscribers(node, function(err, subscribers) {
		if (err) { cb(err); return; }

		t.commit(function(err) {
		    if (err) { cb(err); return; }

		    subscribers.forEach(function(subscriber) {
			/* broadcast */
			callFrontend('notify', subscriber, node, items);
		    });
		});
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

    var args = [].concat(arguments).slice(1);
    var frontend = frontends.hasOwnProperty(proto) && frontends[proto];
    var hookFun = frontend && frontend.hasOwnProperty(hook) && frontend[hook];

    if (hookFun) {
	return hookFun.apply(frontend, args);
    }
};
