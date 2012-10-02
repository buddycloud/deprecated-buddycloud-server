{ EventEmitter } = require('events')
ltx = require('ltx')
should = require('should')

server = require('../lib/server')

class exports.TestServer extends EventEmitter
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

        # Disco replies to the buddycloud server.
        # Elements of @disco.info must be like:
        #     { identities: [{type: "...", name: "...", category: "..."}, ...],
        #       features: [ns1, ns2, ...] }
        # Elements of @disco.items must be like:
        #     [ {item_attr1: val1, item_attr2: val2, ...}, ... ]
        @disco =
            info:
                "test@example.org":
                    identities: []
                    features: []
            items:
                "example.org": [{jid: "buddycloud.example.org"}]

        # Cache IQs sent by the buddycloud server
        @iqs =
            get: {}
            set: {}
            result: {}
            error: {}

        # Cache messages sent by the buddycloud server
        @messages = {}

        @emit "online"

    # Helpers to build XMPP stanzas
    makeIq: (type, from, to, id) ->
        return new ltx.Element "iq",
                type: type
                from: from
                to: to
                id: id

    # Helpers to parse XMPP stanzas
    parseDiscoInfo: (iq) ->
        qEl = iq.getChild("query", "http://jabber.org/protocol/disco#info")
        should.exist(qEl)

        disco =
            identities: []
            features: []

        for identity in qEl.getChildren "identity"
            delete identity.attrs.name
            disco.identities.push identity.attrs
        for feature in qEl.getChildren "feature"
            disco.features.push feature.attrs.var

        return disco

    # Used by the buddycloud server to send XML stanzas to the XMPP server. This
    # parses and route these stanzas. Don't use this in tests! If you want to
    # communicate with the buddycloud server, emit a "stanza" event instead.
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

    doTest: (stanza, event, cb_done, cb_check) ->
        @once event, (data) ->
            try
                cb_check(data)
                cb_done()
            catch e
                cb_done(e)

        @emit "stanza", stanza
