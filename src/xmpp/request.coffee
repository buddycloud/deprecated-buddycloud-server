xmpp = require('node-xmpp')
errors = require('../errors')

##
# A request:
# * Unpacks the request
# * Specifies the operation to run
# * Compiles the response
class exports.Request
    constructor: (stanza) ->
        @iq = stanza
        @actor = new xmpp.JID(stanza.attrs.from).bare().toString()

    ##
    # Is this handler eligible for the request, or proceed to next
    # handler?
    matches: () ->
        false

    ##
    # Empty <iq type='result'/> by default
    reply: (child) ->
        @iq.reply child

    replyError: (error) ->
        @iq.replyError error

    operation: () ->
        undefined

class exports.NotImplemented extends exports.Request
    matches: () ->
        true

    reply: () ->
        @replyError new errors.FeatureNotImplemented("Feature not implemented")


