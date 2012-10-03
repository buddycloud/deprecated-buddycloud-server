{ EventEmitter } = require('events')
ltx = require('ltx')
should = require('should')

server = require('../lib/server')

# Fake XMPP server used to test the buddycloud server
class exports.TestServer extends EventEmitter
    # @property [Object] Info and items discoverable by the buddycloud server.
    disco: {
        info:
            "test@example.org":    { identities: [], features: [] }
            "user1@server-a.org":  { identities: [], features: [] }
            "user2@server-a.org":  { identities: [], features: [] }
            "user@server-b.org":   { identities: [], features: [] }
            "user@server-c.org":   { identities: [], features: [] }
        items:
            "example.org":  [{jid: "buddycloud.example.org"}]
            "server-a.org": [{jid: "buddycloud.example.org"}]
            "server-b.org": [{jid: "buddycloud.server-b.org"}]
            "server-c.org": [{jid: "buddycloud.server-c.org"}]
    }

    # Construct a new test server with a configuration suitable for unit
    # testing.
    constructor: ->
        config =
            modelBackend: "postgres"
            modelConfig:
                host: "localhost"
                port: 5432
                database: "buddycloud-server-test"
                user: "buddycloud-server-test"
                password: "tellnoone"
                poolSize: 4
            xmpp:
                jid: "buddycloud.example.org"
                conn: this
            defaults:
                userChannel:
                    openByDefault: true
                topicChannel:
                    openByDefault: true
            logging:
                level: "TRACE"
                file: "test-suite.log"
            checkCreateNode: -> true
            autosubscribeNewUsers: []
        @server = server.startServer config

        # Cache IQs sent by the buddycloud server
        @iqs =
            get: {}
            set: {}
            result: {}
            error: {}

        # Cache messages sent by the buddycloud server
        @messages = {}

        @emit "online"

    # Prepare an IQ stanza.
    # @return [ltx.Element] `<iq type="TYPE" from="FROM" to="TO" id="ID"/>`
    makeIq: (type, from, to, id) ->
        return new ltx.Element "iq",
                type: type
                from: from
                to: to
                id: id

    # Prepare an XMPP data form element (XEP-0004).
    # @param [Object] fields Fields to add to the form
    # @return [ltx.Element] `<x xmlns="jabber:x:data>...</x>`
    makeForm: (type, form_type, fields) ->
        el = new ltx.Element("x", xmlns: "jabber:x:data", type: type)
            .c("field", var: "FORM_TYPE", type: "hidden")
            .c("value").t(form_type)
            .up().up()
        for name, value of fields
            el.c("field", var: name)
                .c("value").t(value)
                .up().up()
        return el.root()

    # Prepare a disco#info stanza.
    # @return [ltx.Element] Stanza with `<query/>` as active sub-Element
    makeDiscoInfoIq: (from, to, id) ->
        return @makeIq("get", from, to, id)
            .c("query", xmlns: "http://jabber.org/protocol/disco#info")

    # Prepare a disco#items stanza.
    # @return [ltx.Element] Stanza with `<query/>` as active sub-Element
    makeDiscoItemsIq: (from, to, id) ->
        return @makeIq("get", from, to, id)
            .c("query", xmlns: "http://jabber.org/protocol/disco#items")

    # Prepare a PubSub "set" stanza.
    # @return [ltx.Element] Stanza with `<pubsub/>` as active sub-Element
    makePubsubSetIq: (from, to, id) ->
        return @makeIq("set", from, to, id)
            .c("pubsub", xmlns: "http://jabber.org/protocol/pubsub")

    # Parse an XMPP data form.
    # @param [ltx.Element] xEl data form element (`<x/>`)
    # @return [Object] An object mapping field names to their values
    parseForm: (xEl) ->
        fields = {}
        for field in xEl.getChildren "field"
            name = field.attrs.var
            value = field.getChildText("value")
            fields[name] = value
        return fields

    # Parse a disco#info result stanza.
    # @param [ltx.Element] iq IQ stanza containing the disco result
    # @return [Object] Parsed results. `attrs` has the attributes of the
    #   `<query/>` element, `identities` the returned identities (without their
    #   name, for easier matching), `features` the returned features, and `form`
    #   a parsed data form if there was one.
    parseDiscoInfo: (iq) ->
        qEl = iq.getChild("query", "http://jabber.org/protocol/disco#info")
        should.exist(qEl)

        disco =
            attrs: qEl.attrs
            identities: []
            features: []

        for identity in qEl.getChildren "identity"
            delete identity.attrs.name
            disco.identities.push identity.attrs
        for feature in qEl.getChildren "feature"
            disco.features.push feature.attrs.var

        xEl = qEl.getChild("x", "jabber:x:data")
        if xEl?
            disco.form = @parseForm xEl

        return disco

    # Run an asynchronous test safely.
    # @param [ltx.Element] stanza Stanza to send to the buddycloud server
    # @param [String] event Event that should be triggered by the sent stanza,
    #   e.g. `iq-<type>-<id>`
    # @param [callback] cb_done Function to call when the test is over or when
    #   an exception has been caught
    # @param [callback] cb_check Function to call when event is received
    doTest: (stanza, event, cb_done, cb_check) ->
        @once event, (data) ->
            try
                cb_check(data)
                cb_done()
            catch e
                cb_done(e)

        @emit "stanza", stanza.root()

    # Used by the buddycloud server to send XML stanzas to the XMPP server.
    #
    # This parses and route these stanzas. Don't use this in tests! If you want
    # to communicate with the buddycloud server, emit a "stanza" event instead.
    # @private
    send: (data) ->
        stanza = ltx.parse(data)
        switch stanza.name
            when "iq"
                stanza.attrs.should.have.property "from"
                stanza.attrs.should.have.property "to"
                stanza.attrs.should.have.property "type"
                type = stanza.attrs.type
                [ "get", "set", "result", "error"].should.include type
                stanza.attrs.should.have.property "id"
                id = stanza.attrs.id

                @iqs[type][id] = stanza
                @emit "got-iq-#{type}-#{id}", stanza

                # Handle disco queries
                if type is "get"
                    if stanza.getChild("query", "http://jabber.org/protocol/disco#info")? and stanza.attrs.to of @disco.info
                        info = @disco.info[stanza.attrs.to]
                        queryEl = new ltx.Element("query", xmlns: "http://jabber.org/protocol/disco#info")
                        for identity in info.identities
                            queryEl.c "identity", identity
                        for feature in info.features
                            queryEl.c "feature",
                                var: feature
                        iq = @makeIq("result", stanza.attrs.to, stanza.attrs.from, id)
                            .cnode(queryEl)
                            .root()
                        @emit "stanza", iq
                    if stanza.getChild("query", "http://jabber.org/protocol/disco#items")? and stanza.attrs.to of @disco.items
                        items = @disco.items[stanza.attrs.to]
                        queryEl = new ltx.Element("query", xmlns: "http://jabber.org/protocol/disco#items")
                        for item in items
                            queryEl.c "item", item
                        iq = @makeIq("result", stanza.attrs.to, stanza.attrs.from, id)
                            .cnode(queryEl)
                            .root()
                        @emit "stanza", iq
            else
                @emit "got-stanza", stanza
