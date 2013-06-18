{ EventEmitter } = require('events')
ltx = require('ltx')
should = require('should')
moment = require('moment')

server = require('../lib/server')
NS = require('../lib/xmpp/ns')

# Useful namespaces
NS.ATOM = "http://www.w3.org/2005/Atom"
NS.AS   = "http://activitystrea.ms/spec/1.0/"
NS.THR  = "http://purl.org/syndication/thread/1.0"
NS.TS   = "http://purl.org/atompub/tombstones/1.0"

exports.NS = NS

class ErrorStanza extends Error
    constructor: (@stanza) ->
        @message = "ErrorStanza: #{@stanza.toString()}"

# Fake XMPP server used to test the buddycloud server
class exports.TestServer extends EventEmitter
    # @property [Object] Info and items discoverable by the buddycloud server.
    serverInfo =
        identities: [
            { category: "pubsub", type: "service" },
            { category: "pubsub", type: "channels" },
            { category: "pubsub", type: "inbox" }
        ]
        features: []
    disco: {
        info:
            "picard@enterprise.sf":     { identities: [], features: [] }
            "riker@enterprise.sf":      { identities: [], features: [] }
            "data@enterprise.sf":       { identities: [], features: [] }
            "laforge@enterprise.sf":    { identities: [], features: [] }
            "sisko@ds9.sf":             { identities: [], features: [] }
            "odo@ds9.sf":               { identities: [], features: [] }
            "dax@ds9.sf":               { identities: [], features: [] }
            "janeway@voyager.sf":       { identities: [], features: [] }
            "neelix@voyager.sf":        { identities: [], features: [] }
            "7of9@voyager.sf":          { identities: [], features: [] }
            "buddycloud.ds9.sf":        serverInfo
            "buddycloud.voyager.sf":    serverInfo

            "test@example.org":         { identities: [], features: [] }
            "mam-user.1@enterprise.sf": { identities: [], features: [] }
            "mam-user.2@enterprise.sf": { identities: [], features: [] }
            "push.1@enterprise.sf":     { identities: [], features: [] }
            "push.2@enterprise.sf":     { identities: [], features: [] }
            "push.1@ds9.sf":            { identities: [], features: [] }
            "push.2@ds9.sf":            { identities: [], features: [] }
            "push.3@ds9.sf":            { identities: [], features: [] }
        items:
            "example.org":   [{jid: "buddycloud.example.org"}]
            "enterprise.sf": [{jid: "buddycloud.example.org"}]
            "ds9.sf":        [{jid: "buddycloud.ds9.sf"}]
            "voyager.sf":    [{jid: "buddycloud.voyager.sf"}]
    }

    # Construct a new test server with a configuration suitable for unit
    # testing.
    constructor: ->
        dbUser = if process.env["TRAVIS"] is "true" then "postgres" else "buddycloud-server-test"
        @config =
            testMode: true
            modelBackend: "postgres"
            modelConfig:
                host: "localhost"
                port: 5432
                database: "buddycloud-server-test"
                user: dbUser
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
            pusherJid: "pusher.example.org"
            autosubscribeNewUsers: []
        @server = server.startServer @config

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
        el = new ltx.Element("x", xmlns: NS.DATA, type: type)
            .c("field", var: "FORM_TYPE", type: "hidden")
            .c("value").t(form_type)
            .up().up()
        for name, value of fields
            el.c("field", var: name)
                .c("value").t(value)
                .up().up()
        return el.root()

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

    # Prepare a disco#info stanza.
    # @return [ltx.Element] Stanza with `<query/>` as active sub-Element
    makeDiscoInfoIq: (from, to, id) ->
        return @makeIq("get", from, to, id)
            .c("query", xmlns: NS.DISCO_INFO)

    # Parse a disco#info result stanza.
    # @param [ltx.Element] iq IQ stanza containing the disco result
    # @return [Object] Parsed results. `attrs` has the attributes of the
    #   `<query/>` element, `identities` the returned identities (without their
    #   name, for easier matching), `features` the returned features, and `form`
    #   a parsed data form if there was one.
    parseDiscoInfo: (iq) ->
        qEl = iq.getChild("query", NS.DISCO_INFO)
        should.exist qEl, "missing element: <query/>"

        disco =
            attrs: qEl.attrs
            identities: []
            features: []

        for identity in qEl.getChildren "identity"
            delete identity.attrs.name
            disco.identities.push identity.attrs
        for feature in qEl.getChildren "feature"
            disco.features.push feature.attrs.var

        xEl = qEl.getChild("x", NS.DATA)
        if xEl?
            disco.form = @parseForm xEl

        return disco

    # Prepare a disco#items stanza.
    # @return [ltx.Element] Stanza with `<query/>` as active sub-Element
    makeDiscoItemsIq: (from, to, id) ->
        return @makeIq("get", from, to, id)
            .c("query", xmlns: NS.DISCO_ITEMS)

    # Prepare a PubSub "get" stanza.
    # @return [ltx.Element] Stanza with `<pubsub/>` as active sub-Element
    makePubsubGetIq: (from, to, id) ->
        return @makeIq("get", from, to, id)
            .c("pubsub", xmlns: NS.PUBSUB)

    # Prepare a PubSub "set" stanza.
    # @return [ltx.Element] Stanza with `<pubsub/>` as active sub-Element
    makePubsubSetIq: (from, to, id) ->
        return @makeIq("set", from, to, id)
            .c("pubsub", xmlns: NS.PUBSUB)

    # Prepare a PubSub#Owner "set" stanza.
    # @return [ltx.Element] Stanza with `<pubsub/>` as active sub-Element
    makePubsubOwnerSetIq: (from, to, id) ->
        return @makeIq("set", from, to, id)
            .c("pubsub", xmlns: NS.PUBSUB_OWNER)

    # Prepare a PubSub event message.
    # @return [ltx.Element] Message stanza with `<event/>` as active sub-Element
    makePubsubEventMessage: (from, to) ->
        return new ltx.Element("message", type: "headline", from: from, to: to)
            .c("event", xmlns: NS.PUBSUB_EVENT)

    # Prepare an Atom element.
    # @param [Object] opts Data to store in the Atom
    # @options opts [String] author Name of the author
    # @options opts [String] author_uri URI of the author account
    # @options opts [String] content Post content
    # @options opts [String] id Post ID
    # @options opts [String] in_reply_to ID of the original post
    # @options opts [String] link Post link
    # @options opts [String] object Object type (comment or note)
    # @options opts [String] published Publication date
    # @options opts [String] updated Update date
    # @options opts [String] verb Post verb (comment or post)
    # @reeturn [ltx.Element] Atom element
    makeAtom: (opts) ->
        atom = new ltx.Element("entry", xmlns: NS.ATOM)
        if opts.author or opts.author_uri
            author = atom.c("author")
            if opts.author
                author.c("name").t(opts.author)
            if opts.author_uri
                author.c("uri").t(opts.author_uri)
        if opts.content
            atom.c("content").t(opts.content)
        if opts.id
            atom.c("id").t(opts.id)
        if opts.in_reply_to
            atom.c("in-reply-to", xmlns: NS.THR, ref: opts.in_reply_to)
        if opts.link
            atom.c("link", rel: "self", href: opts.link)
        if opts.object
            atom.c("object", xmlns: NS.AS).c("object-type").t(opts.object)
        atom.c("published").t(if opts.published? then opts.published else moment.utc().format())
        atom.c("updated").t(if opts.updated? then opts.updated else moment.utc().format())
        if opts.verb
            atom.c("verb", xmlns: NS.AS).t(opts.verb)
        return atom

    # Parse an Atom element.
    # @param [ltx.Element] entryEl Atom element
    # @return [Object] Object with the same content as the parameter of
    #   #makeAtom
    parseAtom: (entry) ->
        entry.is("entry", NS.ATOM).should.be.ok
        atom =
            author: entry.getChild("author")?.getChildText "name"
            author_uri: entry.getChild("author")?.getChildText "uri"
            in_reply_to: entry.getChild("in-reply-to", NS.THR)?.attrs.ref
            link: entry.getChild("link")?.attrs.href
            object: entry.getChild("object", NS.AS)?.getChildText("object-type")
            verb: entry.getChild("verb", NS.AS)?.getText()
        for name in ["content", "id", "published", "updated"]
            atom[name] = entry.getChildText name
        return atom

    # Prepare a PubSub "set" IQ for publishing an Atom to a PubSub node
    # @param [Object] atomOpts Data to store in the atom
    # @return [ltx.Element] IQ stanza
    makePublishIq: (from, to, id, node, atomOpts) ->
        return @makePubsubSetIq(from, to, id)
            .c("publish", node: node)
            .c("item", id: atomOpts.id)
            .cnode @makeAtom atomOpts

    # Run an asynchronous test safely.
    # @param [ltx.Element] stanza Stanza to send to the buddycloud server
    # @param [String] event Event that should be triggered by the sent stanza,
    #   e.g. `iq-<type>-<id>`
    # @param [callback] cb_done Function to call when the test is over or when
    #   an exception has been caught
    # @param [callback] cb_check Function to call when event is received
    doTest: (stanza, event, cb_done, cb_check) ->
        @removeAllListeners event
        @once event, (data) ->
            try
                cb_check(data)
                cb_done()
            catch e
                cb_done(e)

        @emit "stanza", stanza.root()

    # Run an asynchronous test that triggers several stanzas.
    # @param [ltx.Element] stanza Stanza to send to the buddycloud server
    # @param [callback] cb_done Function to call when all the tests are over or
    #   when an exception has been caught
    # @param [Object] events A mapping of event names to check functions
    # @param [Array<String>] badEvents A list of events that should not happen
    doTests: (stanza, cb_done, events, badEvents) ->
        eventsLeft = 0
        cb_partial = ->
            eventsLeft -= 1
            if eventsLeft == 0
                cb_done()

        runner = (cb_check) ->
            return (data) ->
                try
                    cb_check(data)
                    cb_partial()
                catch e
                    cb_done(e)

        for event, cb_check of events
            eventsLeft += 1
            @removeAllListeners event
            @once event, runner cb_check

        badRunner = (event) ->
            return (data) ->
                process.nextTick ->
                    cb_done new Error "bad event: #{event}"

        if badEvents?
            for event in badEvents
                @removeAllListeners event
                @once event, badRunner event

        @emit "stanza", stanza.root()

    # Used by the buddycloud server to send XML stanzas to the XMPP server.
    #
    # This parses and route these stanzas. Don't use this in tests! If you want
    # to communicate with the buddycloud server, emit a "stanza" event instead.
    # @private
    send: (data) ->
        stanza = if data instanceof ltx.Element then data else ltx.parse data
        switch stanza.name
            when "presence"
                stanza.attrs.should.have.property "to"
                stanza.attrs.should.have.property "type"
                if stanza.attrs.type is "probe"
                    # Reply to presence probes. If the probed JID is a client,
                    # reply with 2 online resources: "abc" and "def".
                    to = stanza.attrs.from ? @config.xmpp.jid
                    bareFrom = stanza.attrs.to
                    if "@" in bareFrom
                        froms = [bareFrom + "/abc", bareFrom + "/def"]
                    else
                        froms = [bareFrom]
                    for from in froms
                        p = new ltx.Element("presence", from: from, to: to)
                        @emit "stanza", p.root()

            when "iq"
                stanza.attrs.should.have.property "from"
                stanza.attrs.should.have.property "to"
                to = stanza.attrs.to
                stanza.attrs.should.have.property "type"
                type = stanza.attrs.type
                [ "get", "set", "result", "error"].should.include type
                stanza.attrs.should.have.property "id"
                id = stanza.attrs.id

                @iqs[type][id] = stanza
                eventId = "got-iq-#{id}"
                eventTo = "got-iq-to-#{to}"

                # If it's an error, throw an exception unless it was expected
                if type is "error" and @listeners(eventId).length == 0
                    throw new ErrorStanza stanza

                # Handle disco queries. The tests don't need to know about them.
                handled = false
                if type is "get"
                    if stanza.getChild("query", NS.DISCO_INFO)? and stanza.attrs.to of @disco.info
                        info = @disco.info[stanza.attrs.to]
                        queryEl = new ltx.Element("query", xmlns: NS.DISCO_INFO)
                        for identity in info.identities
                            queryEl.c "identity", identity
                        for feature in info.features
                            queryEl.c "feature",
                                var: feature
                        iq = @makeIq("result", stanza.attrs.to, stanza.attrs.from, id)
                            .cnode(queryEl)
                        @emit "stanza", iq.root()
                        handled = true
                    if stanza.getChild("query", NS.DISCO_ITEMS)? and stanza.attrs.to of @disco.items
                        items = @disco.items[stanza.attrs.to]
                        queryEl = new ltx.Element("query", xmlns: NS.DISCO_ITEMS)
                        for item in items
                            queryEl.c "item", item
                        iq = @makeIq("result", stanza.attrs.to, stanza.attrs.from, id)
                            .cnode(queryEl)
                        @emit "stanza", iq.root()
                        handled = true

                unless handled
                    @emit eventId, stanza
                    @emit eventTo, stanza

            when "message"
                stanza.attrs.should.have.property "from"
                stanza.attrs.should.have.property "to"

                to = stanza.attrs.to
                if to of @messages
                    @messages[to].push stanza
                else
                    @messages[to] = [stanza]

                @emit "got-message-#{to}", stanza

            else
                @emit "got-stanza", stanza
