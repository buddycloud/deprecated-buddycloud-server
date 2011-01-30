process.on('uncaughtException', function(err) {
    console.error('uncaughtException: ' + (err.stack || err.message || err.toString()));
});

var config = require('./config');

var model = require('./model_' + config.modelBackend);
model.start(config.modelConfig);

var controller = require('./controller');
controller.setModel(model);

var xmpp = require('./xmpp_pubsub');
xmpp.setController(controller);
xmpp.start(config);
