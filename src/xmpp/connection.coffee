###
# Encapsulate XMPP Component connection
#
# * Provide <iq/> RPC interface
# * Track presence
###
xmpp = require("node-xmpp")
{EventEmitter} = require('events')
errors = require("../errors")
ns = require('./ns')

IQ_TIMEOUT = 10000
MAX_STANZA_SIZE = 65000  # 535 bytes spare room
MISSED_INTERVAL = 120 * 1000

##
# XMPP Component Connection,
# encapsulates the real node-xmpp connection
class exports.Connection extends EventEmitter
    constructor: (config) ->
        # For iq response tracking (@sendIq):
        @lastIqId = 0
        @iqCallbacks = {}
        # For <you-missed-something/> sending
        @missedServerTimeouts = {}

        # For presence tracking:
        @onlineResources = {}

        # Setup connection:
        @jid = config.jid
        @conn = new xmpp.Component(config)
        @conn.on "online", =>
            @emit "online"
        @conn.on "stanza", (stanza) =>
            # Just debug output:
            console.log "<< #{stanza.toString()}"
            from = stanza.attrs.from

            switch stanza.name
                when "iq"
                    switch stanza.attrs.type
                        when "get", "set"
                            # IQ requests
                            @_handleIq stanza
                        when "result" , "error"
                            # IQ replies
                            @iqCallbacks.hasOwnProperty(stanza.attrs.id)
                            cb = @iqCallbacks[stanza.attrs.id]
                            delete @iqCallbacks[stanza.attrs.id]
                            if stanza.attrs.type is 'error'
                                # TODO: wrap into new Error(...)
                                cb and cb(stanza)
                            else
                                cb and cb(null, stanza)
                when "presence"
                    @_handlePresence stanza
                when "message"
                    if stanza.attrs.type isnt "error"
                        @_handleMessage stanza
                    else if from.indexOf('@') < 0
                        unless @missedServerTimeouts.hasOwnProperty(from)
                            # We've got an error back from a component,
                            # which are not subject to presence and must
                            # be probed manually.
                            @missedServerTimeouts[from] = setTimeout =>
                                delete @missedServerTimeouts[from]
                                @send new xmpp.Element('message',
                                    type: 'headline'
                                    from: @jid
                                    to: from
                                ).c('you-missed-something', xmlns: NS.BUDDYCLOUD_V1)
                            , MISSED_INTERVAL

    send: (stanza) ->
        stanza = stanza.root()
        unless stanza.attrs.from
            stanza.attrs.from = @jid

        bytes = 0
        stanza.root().write (s) ->
            bytes += Buffer.byteLength(s)
        if bytes > MAX_STANZA_SIZE
            console.warn "Stanza with #{bytes} bytes: #{stanza.toString().substr(0, 127)}..."
            throw new errors.MaxStanzaSizeExceeded(bytes)

        console.log ">> #{stanza.toString()}"
        @conn.send stanza

    ##
    # @param {Function} cb: Called with (errorStanza, resultStanza)
    sendIq: (iq, cb) ->
        # Generate a new unique request id
        @lastIqId += Math.ceil(Math.random() * 999)
        id = iq.attrs.id = "#{@lastIqId}"
        # Set up timeout
        timeout = setTimeout () =>
            delete @iqCallbacks[id]
            cb(new Error('timeout'))
        , IQ_TIMEOUT
        # Wrap callback to cancel timeout in case of success
        @iqCallbacks[id] = (error, result) ->
            clearTimeout timeout
            cb(error, result)
        # Finally, send out:
        @send iq

    _handleMessage: (message) ->
        @emit 'message', message

    ##
    # Returns all full JIDs we've seen presence from for a bare JID
    # @param {String} bareJid
    getOnlineResources: (bareJid) ->
        if @onlineResources.hasOwnProperty(bareJid)
            @onlineResources[bareJid].map (resource) ->
                jid = new xmpp.JID(bareJid)
                jid.resource = resource
                jid.toString()
         else
            []

    subscribePresence: (jid) ->
        unless @onlineResources.hasOwnProperty(jid)
            @send new xmpp.Element("presence",
                to: jid
                type: "subscribe"
            )

    _handlePresence: (presence) ->
        jid = new xmpp.JID(presence.attrs.from)
        bareJid = jid.bare().toString()
        resource = jid.resource

        rmUserResource = () =>
            if @onlineResources[bareJid]?
                # Remove specific resource
                @onlineResources[bareJid] =
                     @onlineResources[bareJid].filter (r) ->
                        r != resource
                # No resources left?
                if @onlineResources[bareJid].length < 1
                    delete @onlineResources[bareJid]
                    @emit 'userOffline', bareJid

        switch presence.attrs.type
            when "subscribe"
                # User subscribes to us
                @send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                    type: "subscribed"
                )
            when "unsubscribe"
                # User unsubscribes from us
                @send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                    type: "unsubscribed"
                )
            when "probe"
                # We are always available
                @send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                ).c("status").t("buddycloud-server")

            when "subscribed" then
                # User allowed us subscription
            when "unsubscribed" then
                # User denied us subscription

            when "error"
                # Error from a bare JID?
                unless resource
                    # Remove all resources
                    delete @onlineResources[bareJid]
                else
                     rmUserResource()
            when "unavailable"
                rmUserResource()
            else # available
                @onlineResources[bareJid] = [] unless bareJid of @onlineResources
                if @onlineResources[bareJid].indexOf(resource) < 0
                    @onlineResources[bareJid].push resource

    _handleIq: (stanza) ->
        ##
        # Prepare stanza reply hooks

        # Safety first:
        replied = false
        replying = () ->
            if replied
                throw 'Sending additional iq reply'

        # Interface for <iq type='result'/>
        stanza.reply = (child) =>
            replying()

            reply = new xmpp.Element("iq",
                from: stanza.attrs.to
                to: stanza.attrs.from
                id: stanza.attrs.id or ""
                type: "result"
            )
            reply.cnode(child.root()) if child?.children?

            @send reply
            replied = true
        # Interface for <iq type='error'/>
        stanza.replyError = (err) =>
            replying()

            reply = new xmpp.Element("iq",
                from: stanza.attrs.to
                to: stanza.attrs.from
                id: stanza.attrs.id or ""
                type: "error"
            )
            if err.xmppElement
                reply.cnode err.xmppElement()
            else
                reply.c("error", type: "cancel").
                    c("text").
                    t('' + err.message)

            @send reply

        ##
        # Fire handler, done.
        @emit 'iqRequest', stanza

    probePresence: (user) ->
        sendPresence = (type) =>
            @conn.send new xmpp.Element('presence',
                type: type
                from: @conn.jid
                to: user
            )
        sendPresence 'subscribe'
        sendPresence 'probe'
