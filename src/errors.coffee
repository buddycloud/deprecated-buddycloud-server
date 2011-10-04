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

class exports.Forbidden extends ServerError
    condition: "forbidden"
    type: "auth"

class exports.Conflict extends ServerError
    condition: "conflict"
    type: "cancel"

class exports.BadRequest extends ServerError
    condition: "bad-request"
    type: "modify"

class exports.FeatureNotImplemented extends ServerError
    condition: "feature-not-implemented"
    type: "cancel"

class exports.InternalServerError extends ServerError
    condition: "internal-server-error"
    type: "cancel"

class exports.NotFound extends ServerError
    condition: "item-not-found"
    type: "cancel"

class exports.NotAllowed extends ServerError
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

##
# Signaling the router that a node is actually local
class exports.SeeLocal extends Error
    constructor: ->
        super("Locally stored")

##
# Thrown by Connection.send()
class exports.MaxStanzaSizeExceeded extends Error
    constructor: (bytes) ->
        super("Maximum stanza size exceeded (#{bytes} bytes)")
