try
    inherits = require("util").inherits
catch x
    try
        inherits = require("utils").inherits
    catch x
        inherits = require("sys").inherits
xmpp = require("node-xmpp")
NS_XMPP_STANZAS = "urn:ietf:params:xml:ns:xmpp-stanzas"

##
# Base class for our well-defined error conditions
class ServerError extends Error
    constructor: (message) ->
        #super/Error.apply this, arguments

        # Isn't message set by Error()?
        @message = message

    condition: 'undefined-condition'
    type: 'cancel'

    xmppElement: ->
        errorEl = new xmpp.Element("error", type: @type)
        errorEl.c @condition, xmlns: NS_XMPP_STANZAS
        if @message
            console.log message: @message
            errorEl.c("text", xmlns: NS_XMPP_STANZAS).t @message
        errorEl

##
# Creates the subclasses of ServerError
makePrototype = (condition, type) ->
    p = ->
        ServerError.apply this, arguments
    inherits p, ServerError

    if condition
        p.prototype.condition = condition
    if type
        p.prototype.type = type
    p

##
# The actual exported error classes
module.exports =
    Forbidden: makePrototype("forbidden", "auth")
    Conflict: makePrototype("conflict", "cancel")
    BadRequest: makePrototype("bad-request", "modify")
    FeatureNotImplemented: makePrototype("feature-not-implemented", "cancel")
    InternalServerError: makePrototype("internal-server-error", "wait")
    NotFound: makePrototype("item-not-found", "cancel")
    NotAllowed: makePrototype("not-allowed", "cancel")
