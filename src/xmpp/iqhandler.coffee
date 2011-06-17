class exports.Handler
    constructor: (conn, stanza) ->
        @conn = conn
        @iq = stanza

    ##
    # Is this handler eligible for the request, or proceed to next
    # handler?
    matches: () ->
        false

    run: () ->

    reply: (child) ->
        reply = new xmpp.Element("iq",
            from: @iq.attrs.to
            to: @iq.attrs.from
            id: @iq.attrs.id or ""
            type: "result"
        )
        reply.cnode(child.root()) if child

        @conn.send reply

    replyError: (err) ->
        reply = new xmpp.Element("iq",
            from: @iq.attrs.to
            to: @iq.attrs.from
            id: @iq.attrs.id or ""
            type: "error"
        )
        if err.xmppElement
            reply.cnode err.xmppElement()
        else
            reply.c("error", type: "cancel").c("text").t "" + err.message

        @conn.send reply

##
# To match for a group of sub-handlers in a tree-like way
class exports.GroupHandler extends exports.Handler
    constructor: (conn, stanza) ->
        super conn, stanza

        @subhandlers = []

    addHandler: (handler)
        @subhandlers.push handler

    run: () ->
        subhandler = null
        for h in @iqHandlers
            subhandler = new h(stanza)
            if subhandler.matches()
                break
            else
                subhandler = null

class exports.NotImplemented extends exports.Handler
    matches: () ->
        true

    run: () ->
        @replyError(new errors.FeatureNotImplemented("Feature is not implemented"))
