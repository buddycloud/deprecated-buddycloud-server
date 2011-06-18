errors = require('../errors')

class exports.Handler
    constructor: (stanza) ->
        @iq = stanza
        @reply = stanza.reply
        @replyError = stanza.replyError

    ##
    # Is this handler eligible for the request, or proceed to next
    # handler?
    matches: () ->
        false

    run: () ->

##
# To match for a group of sub-handlers in a tree-like way
exports.GroupHandler = (subhandlers...) ->
    class groupHandler extends exports.Handler
        matches: () ->
            true

        run: () ->
            console.log 'run groupHandler'
            subhandler = null
            for h in subhandlers
                subhandler = new h(@iq)
                if subhandler.matches()
                    console.log 'found subhandler', subhandler
                    break
                else
                    subhandler = null
            subhandler.run()

    console.log 'groupHandler', groupHandler
    groupHandler

class exports.NotImplemented extends exports.Handler
    matches: () ->
        true

    run: () ->
        @replyError(new errors.FeatureNotImplemented("Feature is not implemented"))

