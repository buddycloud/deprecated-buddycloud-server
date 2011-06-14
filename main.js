#!/usr/bin/env node

process.on('uncaughtException', function(err) {
    console.error('uncaughtException: ' + (err.stack || err.message || err.toString()));
});

process.chdir(__dirname);
var config = require('./config');

var model = require('./build/default/model_' + config.modelBackend);
model.start(config.modelConfig);

var controller = require('./build/default/controller');
controller.setModel(model);

var xmpp = require('./build/default/xmpp_pubsub');
xmpp.setController(controller);
xmpp.start(config);
