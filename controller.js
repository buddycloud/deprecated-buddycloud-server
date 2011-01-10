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
	t.writeItems(publisher, node, items, function(err) {
	    /* TODO: broadcast */
	    t.commit(cb);
	});
    });
};
