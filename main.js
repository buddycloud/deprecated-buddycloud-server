var config = require('./config');

var model = require('./model_couchdb');
var controller = require('./controller');
controller.setModel(model);

var xmpp = require('./xmpp_pubsub');
xmpp.setController(controller);
xmpp.start(config);
