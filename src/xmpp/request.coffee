errors = require('../errors')

##
# A request:
# * Unpacks the request
# * Specifies the operation to run
# * Compiles the response
class exports.Request
    constructor: (stanza) ->
        @iq = stanza
        @reply = stanza.reply
        @replyError = stanza.replyError

    ##
    # Is this handler eligible for the request, or proceed to next
    # handler?
    matches: () ->
        false

    reply: () ->
        @replyError(new errors.FeatureNotImplemented("Feature is not implemented"))

    operation: () ->
        undefined

class exports.NotImplemented extends exports.Request
    matches: () ->
        true

    # The default exports.Handler::run is already FeatureNotImplemented

