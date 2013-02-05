{ TestServer } = require('./test_server')

describe "buddycloud-server", ->
    server = new TestServer()

    it "should support Software Version requests (XEP-0092)", (done) ->
        iq = server.makeIq("get", "test@example.org", "buddycloud.example.org", "info1")
            .c("query", xmlns: "jabber:iq:version")
            .root()

        server.doTest iq, "got-iq-info1", done, (iq) ->
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
        iq = server.makeDiscoInfoIq "test@example.org", "buddycloud.example.org", "disco1"

        server.doTest iq, "got-iq-disco1", done, (iq) ->
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
                "http://jabber.org/protocol/pubsub#config-node",
                "http://jabber.org/protocol/pubsub#delete-items",
                "http://jabber.org/protocol/pubsub#get-pending",
                "http://jabber.org/protocol/pubsub#item-ids",
                "http://jabber.org/protocol/pubsub#manage-subscriptions",
                "http://jabber.org/protocol/pubsub#meta-data",
                "http://jabber.org/protocol/pubsub#modify-affiliations",
                "http://jabber.org/protocol/pubsub#outcast-affiliation",
                "http://jabber.org/protocol/pubsub#owner",
                "http://jabber.org/protocol/pubsub#publish",
                "http://jabber.org/protocol/pubsub#publisher-affiliation",
                "http://jabber.org/protocol/pubsub#purge-nodes",
                "http://jabber.org/protocol/pubsub#retract-items",
                "http://jabber.org/protocol/pubsub#retrieve-affiliations",
                "http://jabber.org/protocol/pubsub#retrieve-items",
                "http://jabber.org/protocol/pubsub#retrieve-subscriptions",
                "http://jabber.org/protocol/pubsub#subscribe",
                "http://jabber.org/protocol/pubsub#subscription-options",
                "http://jabber.org/protocol/pubsub#subscription-notifications",
                "jabber:iq:register",
                "jabber:iq:version",
                "urn:xmpp:mam:tmp"
            ]
            for feature in expectedFeatures
                disco.features.should.include feature

    it "should support disco#items (XEP-0030)", (done) ->
        iq = server.makeDiscoItemsIq "test@example.org", "buddycloud.example.org", "disco2"

        server.doTest iq, "got-iq-disco2", done, (iq) ->
            iq.attrs.should.eql
                from: "buddycloud.example.org"
                to: "test@example.org"
                id: "disco2"
                type: "result"
            iq.children.should.have.length 1

            q = iq.children[0]
            q.should.have.property "name", "query"
            q.attrs.should.have.property "xmlns", "http://jabber.org/protocol/disco#items"

    it "should have a valid example configuration file", ->
        # Just check if it compiles (in case of a ninja-edit on GitHub)
        require.extensions['.example'] = require.extensions['.js']
        conf = require('../config.js.example')
