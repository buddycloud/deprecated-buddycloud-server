xmpp = require("node-xmpp")
uuid = require("node-uuid")
errors = require("./errors")

IQ_TIMEOUT = 10000

##
# XMPP Component Connection,
# encapsulates the real node-xmpp connection
class exports.Connection
    constructor: (config) ->
        # For iq response tracking (@sendIq):
        @lastIqId = 0
        @iqCallbacks = {}

        # For presence tracking:
        @onlineResources = {}

        # Setup connection:
        @conn = new xmpp.Component(config.xmpp)
        @conn.on "online", startPresenceTracking
        @conn.on "stanza", (stanza) =>
            # Just debug output:
            console.log stanza.toString()

            # IQ replies
            if stanza.name is 'iq' and
               (stanza.attrs.type is 'result' or
                stanza.attrs.type is 'error') and
               stanza.attrs.id? and
               @iqCallbacks.hasOwnProperty(stanza.attrs.id)
                cb = @iqCallbacks[stanza.attrs.id]
                delete @iqCallbacks[stanza.attrs.id]
                if stanza.attrs.type is 'error'
                    cb(stanza)
                else
                    cb(null, stanza)
                # Don't handle further
                return

            # Serve requests
            switch stanza.name
                when "iq"
                    switch stanza.attrs.type
                        when "get"
                        when "set"
                            @_handleIq stanza
                when "presence"
                    @_handlePresence stanza
                when "message" and stanza.attrs.type isnt "error"
                    @_handleMessage stanza

    ##
    # @param {Function} cb: Called with (errorStanza, resultStanza)
    sendIq: (iq, cb) ->
        # Generate a new unique request id
        @lastId += Math.ceil(Math.random() * 999)
        id = iq.attrs.id = "#{@lastId}"
        # Set up timeout
        timeout = setTimeout () =>
            delete @iqCallbacks[id]
            cb(new Error('timeout'))
        , IQ_TIMEOUT
        # Wrap callback to cancel timeout in case of success
        @iqCallbacks[id] = (error, result) ->
            cancelTimeout timeout
            cb error, result
        # Finally, send out:
        @conn.send iq

    _handleMessage: (message) ->

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
            @conn.send new xmpp.Element("presence",
                to: jid
                from: @conn.jid
                type: "subscribe"
            )

    _handlePresence: (presence) ->
        jid = new xmpp.JID(presence.attrs.from)
        userId = jid.bare().toString()
        resource = jid.resource

        rmUserResource = () =>
            if @onlineResources[user]?
                # Remove specific resource
                @onlineResources[user] =
                     @onlineResources[user].filter (r) ->
                        r != resource
                # No resources left?
                if @onlineResources[user].length < 1
                    delete @onlineResources[user]

        switch presence.attrs.type
            when "subscribe"
                # User subscribes to us
                @conn.send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                    type: "subscribed"
                )
            when "unsubscribe"
                # User unsubscribes from us
                @conn.send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                    type: "unsubscribed"
                )
            when "probe"
                # We are always available
                @conn.send new xmpp.Element("presence",
                    from: presence.attrs.to
                    to: presence.attrs.from
                    id: presence.attrs.id
                ).c("status").t("buddycloud channel-server")

            when "subscribed"
                # User allowed us subscription
            when "unsubscribed"
                # User denied us subscription

            when "error"
                # Error from a bare JID?
                unless resource
                    # Remove all resources
                    delete @onlineResources[user]
                else
                     rmUserResource()
            when "unavailable"
                rmUserResource()
            else # available
                @onlineResources[user] = [] unless user of @onlineResources
                if @onlineResources[user].indexOf(resource) < 0
                    @onlineResources[user].push resource

    _handleIq: (stanza) ->


###
startPresenceTracking = ->
    onlineResources = {}
    controller.getAllSubscribers (err, subscribers) ->
        if not err and subscribers
            subscribers.forEach (subscriber) ->
                if (m = subscriber.match(/^xmpp:(.+)$/))
                    jid = m[1]
                    @conn.send new xmpp.Element("presence",
                        to: jid
                        from: conn.jid
                        type: "probe"
                    )
###

