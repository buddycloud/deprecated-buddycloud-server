var async = require('async');

/* Set by main.js */
var model;
exports.setModel = function(m) {
    model = m;
};

exports.createNode = function(owner, node, cb) {
    model.createNode(owner, node, cb);
};

/*
 * cb(affiliation, error)
 */
exports.subscribeNode = function(subscriber, node, cb) {
    model.subscribeNode(subscriber, node, cb);
};

exports.publishItems = function(publisher, node, items, cb) {
    model.writeItems(publisher, node, items, cb);
    /* TODO: broadcast */
};
