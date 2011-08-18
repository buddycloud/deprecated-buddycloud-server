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
# The actual exported error classes

class exports.Forbidden
    condition: "forbidden"
    type: "auth"

class exports.Conflict
    condition: "conflict"
    type: "cancel"

class exports.BadRequest
    condition: "bad-request"
    type: "modify"

class exports.FeatureNotImplemented
    condition: "feature-not-implemented"
    type: "cancel"

class exports.InternalServerError
    condition: "internal-server-error"
    type: "cancel"

class exports.NotFound
    condition: "item-not-found"
    type: "cancel"

class exports.NotAllowed
    condition: "not-allowed"
    type: "cancel"

##
# For wrapping errors from remote
class exports.StanzaError extends Error
    constructor: (stanza) ->
        @el = stanza.getChild('error')
        @message = @el?.children[0]?.name

    xmppElement: ->
        @el
