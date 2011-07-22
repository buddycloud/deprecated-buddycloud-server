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
        @sender = new xmpp.JID(stanza.attrs.from).bare().toString()
        # can be overwritten by <actor xmlns="#{NS.BUDDYCLOUD_V1}"/>:
        @actor = @sender

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

    setActor: (childEl) ->
        actorEl = childEl?.getChild("actor", NS.BUDDYCLOUD_V1)
        if actorEl?
            @actor = actorEl.getText()
        # Else @actor stays @sender (see @constructor)


class exports.NotImplemented extends exports.Request
    matches: () ->
        true

    reply: () ->
        @replyError new errors.FeatureNotImplemented("Feature not implemented")


