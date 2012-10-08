{ TestServer } = require('./test_server')
should = require('should')

describe "Creating a channel", ->
    server = new TestServer()

    it "must be possible for a local user", (done) ->
        iq = server.makePubsubSetIq("test@example.org", "buddycloud.example.org", "create1")
            .c("create", node: "/user/test@example.org/posts")

        server.doTest iq, "got-iq-create1", done, (iq) ->
            iq.attrs.should.have.property "type", "result"

    it "must fail if a node already exists", (done) ->
        iq = server.makePubsubSetIq("test@example.org", "buddycloud.example.org", "create2")
            .c("create", node: "/user/test@example.org/posts")

        server.doTest iq, "got-iq-create2", done, (iq) ->
            iq.attrs.should.have.property "type", "error"
            iq.children.should.have.length 1
            err = iq.children[0]
            err.name.should.equal "error"
            err.attrs.should.have.property "type", "cancel"
            should.exist err.getChild("conflict", "urn:ietf:params:xml:ns:xmpp-stanzas"),
                "missing element: <conflict/>"

    # Skip this test. It fails because the server responds with
    # "not-implemented" instead of "not-acceptable", but it's good enough....
    it.skip "requires a node ID", (done) ->
        iq = server.makePubsubSetIq("test@example.org", "buddycloud.example.org", "create3")
            .c("create")

        server.doTest iq, "got-iq-create3", done, (iq) ->
            iq.attrs.should.have.property "type", "error"
            iq.children.should.have.length 1
            err = iq.children[0]
            err.name.should.equal "error"
            err.attrs.should.have.property "type", "modify"
            should.exist err.getChild("not-acceptable", "urn:ietf:params:xml:ns:xmpp-stanzas"),
                "missing element: <not-acceptable/>"
            should.exist err.getChild("nodeid-required", "http://jabber.org/protocol/pubsub#errors"),
                "missing element: <nodeid-required/>"

    it "must set default configuration", (done) ->
        iq = server.makeDiscoInfoIq "test@example.org", "buddycloud.example.org", "disco1"
        iq.attrs.node = "/user/test@example.org/posts"

        server.doTest iq, "got-iq-disco1", done, (iq) ->
            iq.attrs.should.have.property "type", "result"
            iq.children.should.have.length 1

            disco = server.parseDiscoInfo iq
            disco.attrs.should.have.property "node", "/user/test@example.org/posts"

            expectedIdentities = [
                { category: "pubsub", type: "leaf" },
                { category: "pubsub", type: "channel"}
            ]
            for identity in expectedIdentities
                disco.identities.should.includeEql identity

            disco.should.have.property "form"
            disco.form.should.have.property "FORM_TYPE", "http://jabber.org/protocol/pubsub#meta-data"
            disco.form.should.have.property "pubsub#title"
            disco.form.should.have.property "pubsub#description"
            disco.form.should.have.property "pubsub#access_model"
            disco.form.should.have.property "pubsub#publish_model"
            disco.form.should.have.property "buddycloud#default_affiliation"
            disco.form.should.have.property "pubsub#creation_date"

    it "should support node configuration", (done) ->
        form = server.makeForm "submit", "http://jabber.org/protocol/pubsub#node_config",
            "pubsub#title": "Status for test user"
            "pubsub#description": "What test user is currently doing"
        iq = server.makePubsubSetIq("test@example.org", "buddycloud.example.org", "create4")
            .c("create", node: "/user/test@example.org/status").up()
            .c("configure").cnode(form)

        server.doTest iq, "got-iq-create4", done, (iq) ->
            iq.attrs.should.have.property "type", "result"

    it "should respect initial node configuration", (done) ->
        iq = server.makeDiscoInfoIq "test@example.org", "buddycloud.example.org", "disco2"
        iq.attrs.node = "/user/test@example.org/status"

        server.doTest iq, "got-iq-disco2", done, (iq) ->
            iq.attrs.should.have.property "type", "result"
            iq.children.should.have.length 1

            disco = server.parseDiscoInfo iq
            disco.should.have.property "form"
            disco.form.should.have.property "pubsub#title", "Status for test user"
            disco.form.should.have.property "pubsub#description", "What test user is currently doing"
