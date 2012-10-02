{ TestServer } = require('./test_server')

describe "buddycloud-server", ->
    server = new TestServer()

    it "should support Software Version requests (XEP-0092)", (done) ->
        iq = server.makeIq("get", "test@example.org", "buddycloud.example.org", "info1")
            .c("query", xmlns: "jabber:iq:version")
            .root()

        server.doTest iq, "got-iq-result-info1", done, (iq) ->
            iq.attrs.should.eql
                from: "buddycloud.example.org"
                to: "test@example.org"
                id: "info1"
                type: "result"
            iq.children.should.have.length 1
            q = iq.children[0]
            q.should.have.property "name", "query"
            # TODO: check for name, version, os

    it "should support disco#info (XEP-0030)", (done) ->
        iq = server.makeIq("get", "test@example.org", "buddycloud.example.org", "disco1")
            .c("query", xmlns: "http://jabber.org/protocol/disco#info")
            .root()

        server.doTest iq, "got-iq-result-disco1", done, (iq) ->
            iq.attrs.should.eql
                from: "buddycloud.example.org"
                to: "test@example.org"
                id: "disco1"
                type: "result"
            iq.children.should.have.length 1

            disco = server.parseDiscoInfo iq

            expectedIdentities = [
                { category: "pubsub", type: "service" },
                { category: "pubsub", type: "channels" },
                { category: "pubsub", type: "inbox" }
            ]
            for identity in expectedIdentities
                disco.identities.should.includeEql identity

            expectedFeatures = [
                "http://jabber.org/protocol/disco#info",
                "http://jabber.org/protocol/disco#items",
                "http://jabber.org/protocol/pubsub",
                "http://jabber.org/protocol/pubsub#create-and-configure",
                "http://jabber.org/protocol/pubsub#create-nodes",
                "http://jabber.org/protocol/pubsub#owner",
                "http://jabber.org/protocol/pubsub#subscription-options",
                "jabber:iq:register",
                "jabber:iq:version"
            ]
            for feature in expectedFeatures
                disco.features.should.include feature

    it "should support disco#items (XEP-0030)", (done) ->
        iq = server.makeIq("get", "test@example.org", "buddycloud.example.org", "disco2")
            .c("query", xmlns: "http://jabber.org/protocol/disco#items")
            .root()

        server.doTest iq, "got-iq-result-disco2", done, (iq) ->
            iq.attrs.should.eql
                from: "buddycloud.example.org"
                to: "test@example.org"
                id: "disco2"
                type: "result"
            iq.children.should.have.length 1

            q = iq.children[0]
            q.should.have.property "name", "query"
            q.attrs.should.have.property "xmlns", "http://jabber.org/protocol/disco#items"
