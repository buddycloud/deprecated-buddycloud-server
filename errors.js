var utils = require('utils');
var xmpp = require('node-xmpp');
var NS_XMPP_STANZAS = 'urn:ietf:params:xml:ns:xmpp-stanzas';

/**
 * Base class for our well-defined error conditions
 */
function ServerError(message) {
    Error.apply(this, arguments);

    /* Isn't message set by Error()? */
    this.message = message;
}
utils.inherits(ServerError, Error);
ServerError.prototype.condition = 'undefined-condition';
ServerError.prototype.type = 'cancel';

ServerError.prototype.xmppElement = function() {
    var errorEl = new xmpp.Element('error', { type: this.type });
    errorEl.c(this.condition, { xmlns: NS_XMPP_STANZAS });
    if (this.message) {
	console.log({message:this.message})
	errorEl.c('text', { xmlns: NS_XMPP_STANZAS }).
	t(this.message);
    }
    return errorEl;
};

/**
 * Creates the subclasses of ServerError
 */
function makePrototype(condition, type) {
    var p = function() {
	ServerError.apply(this, arguments);
    };
    utils.inherits(p, ServerError);

    if (condition)
	p.prototype.condition = condition;
    if (type)
	p.prototype.type = type;

    return p;
}

/**
 * The actual exported error classes
 */
module.exports = {
    Forbidden: makePrototype('forbidden', 'auth'),
    Conflict: makePrototype('conflict', 'cancel'),
    BadRequest: makePrototype('bad-request', 'modify'),
    FeatureNotImplemented: makePrototype('feature-not-implemented', 'cancel'),
    InternalServerError: makePrototype('internal-server-error', 'wait'),
    NotFound: makePrototype('item-not-found', 'cancel')
};
