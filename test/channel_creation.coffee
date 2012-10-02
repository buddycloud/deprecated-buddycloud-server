{ TestServer } = require('./test_server')
should = require('should')

describe "Creating a channel", ->
    server = new TestServer()

    it "must be possible for a local user", (done) ->
        iq = server.makeIq("set", "test@example.org", "buddycloud.example.org", "create1")
            .c("pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            .c("create", node: "/user/test@example.org/posts")
            .root()
        server.doTest iq, "got-iq-result-create1", done, (iq) ->

    it "must fail if a node already exists", (done) ->
        iq = server.makeIq("set", "test@example.org", "buddycloud.example.org", "create1")
            .c("pubsub", xmlns: "http://jabber.org/protocol/pubsub")
            .c("create", node: "/user/test@example.org/posts")
            .root()
        server.doTest iq, "got-iq-error-create1", done, (iq) ->
            iq.children.should.have.length 1
            err = iq.children[0]
            err.name.should.equal "error"
            err.attrs.should.have.property "type", "cancel"
            should.exist(err.getChild("conflict", "urn:ietf:params:xml:ns:xmpp-stanzas"))
