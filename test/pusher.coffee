async = require('async')
should = require('should')
{ inspect } = require('util')
{ NS, TestServer } = require('./test_server')

# {{{ Helpers
testConfigurationMessage = (node) ->
    return (msg) ->
        console.log "\n" + msg.root().toString()
        msg.attrs.should.have.property "from", "buddycloud.example.org"
        cfgEl = msg.getChild("event", NS.PUBSUB_EVENT)
            ?.getChild("configuration")
        should.exist cfgEl, "missing element: <configuration/>"
        cfgEl.attrs.should.have.property "node", node

testPostMessage = (node, id) ->
    return (msg) ->
        msg.attrs.should.have.property "from", "buddycloud.example.org"
        itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
            ?.getChild("items")
        should.exist itemsEl, "missing element: <items/>"
        itemsEl.attrs.should.have.property "node", node
        itemEl = itemsEl.getChild "item"
        should.exist itemEl, "missing element: <item/>"
        itemEl.attrs.should.have.property "id", id
        should.exist itemEl.getChild("entry", NS.ATOM), "missing element: <entry/>"

testSubscription = (server, el, done, node, jid, els) ->
    # els is an object. If it has a "subscription" property, we expect a
    # <subscription/> message. If the expected subscription is "subscribed", we
    # also expect an item in from the subscriptions node. If els has an
    # "affiliation" property, we expect an <affiliations/> message and an item.
    needAff = els.affiliation?
    needSub = els.subscription?
    needItem = els.affiliation? or (els.subscription? and els.subscription is 'subscribed')
    nodeUser = /^\/user\/([^\/]+)\/?(.*)/.exec(node)[1]

    cb = (err) ->
        clearTimeout timeout
        server.removeAllListeners "got-message-pusher.example.org"
        done err

    timeout = setTimeout ->
        cb new Error "#{jid} --> #{node}: needAff: #{needAff}, needSub: #{needSub}, needItem: #{needItem}, els: #{inspect els}"
    , 1000

    server.on "got-message-pusher.example.org", (msg) ->
        msg.attrs.should.have.property "from", "buddycloud.example.org"
        evEl = msg.getChild "event", NS.PUBSUB_EVENT
        should.exist evEl, "missing element: <event/>"

        affEl = evEl.getChild "affiliations"
        if affEl?
            needAff.should.equal true, "unexpected <affiliations/>"
            affEl.attrs.should.have.property "node", node
            for child in affEl.getChildren "affiliation"
                child.attrs.should.have.property "jid"
                child.attrs.should.have.property "affiliation"
                if child.attrs.jid is jid and child.attrs.affiliation is els.affiliation
                    needAff = false

        subEl = evEl.getChild "subscription"
        if subEl?
            needSub.should.equal true, "unexpected <subscription/>"
            subEl.attrs.should.have.property "node", node
            subEl.attrs.should.have.property "jid", jid
            subEl.attrs.should.have.property "subscription", els.subscription
            needSub = false

        itemsEl = evEl.getChild "items"
        if itemsEl?
            needItem.should.equal true, "unexpected <items/>"
            should.exist itemsEl, "missing element: <items/>"
            itemsEl.attrs.should.have.property "node", "/user/#{jid}/subscriptions"
            itemEl = itemsEl.getChild "item"
            should.exist itemEl, "missing element: <item/>"
            itemEl.attrs.should.have.property "id", nodeUser
            qEl = itemEl.getChild("query", NS.DISCO_ITEMS)
            should.exist qEl, "missing element: <query/>"

            # TODO: maybe check pubsub:subscription, pubsub:affiliation, etc.
            needItem = false

        unless needAff or needSub or needItem
            cb null

    server.emit "stanza", el.root()
# }}}
# {{{ Tests
describe "Pusher component", ->
    server = new TestServer()

# {{{ items
    it "should be notified of published items", (done) ->
        async.series [(cb) ->
            # Post to a local channel
            iq = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "push-A-1", "/user/picard@enterprise.sf/posts",
                id: "push-A-1", content: "Test post A1"

            server.doTest iq, "got-message-pusher.example.org", cb,
                testPostMessage "/user/picard@enterprise.sf/posts", "push-A-1"

        , (cb) ->
            # Notification of a post to a remote channel
            entryEl = server.makeAtom content: "Test post A2", author: "sisko@ds9.sf", id: "push-A-2"
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "push-A-2")
                    .cnode(entryEl)

            server.doTest msgEl, "got-message-pusher.example.org", cb,
                testPostMessage "/user/sisko@ds9.sf/posts", "push-A-2"
        ], done

    it "should be notified of retracted items", (done) ->
        async.series [(cb) ->
            # Post
            iq = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "push-A-3", "/user/picard@enterprise.sf/posts",
                id: "push-A-3", content: "Test post A3"

            server.doTest iq, "got-iq-push-A-3", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"

        , (cb) ->
            # Retract
            iq = server.makePubsubSetIq("picard@enterprise.sf", "buddycloud.example.org", "push-A-4")
                .c("retract", node: "/user/picard@enterprise.sf/posts")
                .c("item", id: "push-A-3")

            server.doTest iq, "got-message-pusher.example.org", cb, (msg) ->
                msg.attrs.should.have.property "from", "buddycloud.example.org"
                itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
                    ?.getChild("items")
                should.exist itemsEl, "missing element: <items/>"
                itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"

                retEl = itemsEl.getChild "retract"
                should.exist retEl, "missing element: <retract/>"
                retEl.attrs.should.have.property "id", "push-A-3"

                itemEl = itemsEl.getChild "item"
                should.exist itemEl, "missing element: <item/>"
                itemEl.attrs.should.have.property "id", "push-A-3"
                tsEl = itemEl.getChild "deleted-entry", NS.TS
                should.exist tsEl, "missing element: <deleted-entry/>"
        ], done
# }}}
# {{{ subscriptions
    it "should be notified of new subscriptions and unsubscriptions", (done) ->
        async.series [(cb) ->
            # Local subscription
            iq = server.makePubsubSetIq("push.1@enterprise.sf/abc", "buddycloud.example.org", "push-B-1")
                .c("subscribe", node: "/user/push.2@enterprise.sf/posts", jid: "push.1@enterprise.sf")

            testSubscription server, iq, cb, "/user/push.2@enterprise.sf/posts", "push.1@enterprise.sf",
                subscription: "subscribed"
                affiliation: "member"

        , (cb) ->
            # Local unbsubscription
            iq = server.makePubsubSetIq("push.1@enterprise.sf/abc", "buddycloud.example.org", "push-B-2")
                .c("unsubscribe", node: "/user/push.2@enterprise.sf/posts", jid: "push.1@enterprise.sf")

            testSubscription server, iq, cb, "/user/push.2@enterprise.sf/posts", "push.1@enterprise.sf",
                subscription: "none"
                affiliation: "none"

        , (cb) ->
            # Remote subscription
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("subscription", node: "/user/push.1@ds9.sf/posts", jid: "push.3@ds9.sf", subscription: "subscribed")

            testSubscription server, msgEl, cb, "/user/push.1@ds9.sf/posts", "push.3@ds9.sf",
                subscription: "subscribed"

        , (cb) ->
            # Remote unsubscription
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("subscription", node: "/user/push.1@ds9.sf/posts", jid: "push.3@ds9.sf", subscription: "none")

            testSubscription server, msgEl, cb, "/user/push.1@ds9.sf/posts", "push.3@ds9.sf",
                subscription: "none"
        ], done

    it "should be notified of pending subscriptions", (done) ->
        async.series [(cb) ->
            # Local subscription to a private channel
            iq = server.makePubsubSetIq("push.1@enterprise.sf", "buddycloud.example.org", "push-B-3")
                .c("subscribe", node: "/user/data@enterprise.sf/posts", jid: "push.1@enterprise.sf")

            testSubscription server, iq, cb, "/user/data@enterprise.sf/posts", "push.1@enterprise.sf",
                subscription: "pending"

        , (cb) ->
            # FIXME: should this even be notified?
            # Remote subscription to a private channel
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("subscription", node: "/user/push.2@ds9.sf/posts", jid: "push.1@ds9.sf", subscription: "pending")

            testSubscription server, msgEl, cb, "/user/push.2@ds9.sf/posts", "push.1@ds9.sf",
                subscription: "pending"
        ], done
# }}}
# {{{ affiliations
    it "should be notified of affiliation changes", (done) ->
        async.series [(cb) ->
            # Local: subscription first
            iq = server.makePubsubSetIq("push.2@enterprise.sf/abc", "buddycloud.example.org", "push-C-1")
                .c("subscribe", node: "/user/push.1@enterprise.sf/posts", jid: "push.2@enterprise.sf")

            server.doTest iq, "got-iq-push-C-1", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"

        , (cb) ->
            # Local: change affiliation
            iq = server.makePubsubOwnerSetIq("push.1@enterprise.sf", "buddycloud.example.org", "push-C-2")
                .c("affiliations", node: "/user/push.1@enterprise.sf/posts")
                .c("affiliation", jid: "push.2@enterprise.sf", affiliation: "moderator")

            testSubscription server, iq, cb, "/user/push.1@enterprise.sf/posts", "push.2@enterprise.sf",
                affiliation: "moderator"

        , (cb) ->
            # Remote: change affiliation (push.1@enterprise.sf follows push.3@ds9.sf)
            msg = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("affiliations", node: "/user/push.3@ds9.sf/posts")
                .c("affiliation", jid: "push.1@enterprise.sf", affiliation: "publisher")

            testSubscription server, msg, cb, "/user/push.3@ds9.sf/posts", "push.1@enterprise.sf",
                affiliation: "publisher"
        ], done
# }}}
# {{{ node configuration
    it "should be notified of node configuration updates", (done) ->
        async.series [(cb) ->
            # Local
            iq = server.makePubsubOwnerSetIq("push.1@enterprise.sf", "buddycloud.example.org", "push-D-1")
                .c("configure", node: "/user/push.1@enterprise.sf/status")
                .cnode(server.makeForm("submit", NS.PUBSUB_NODE_CONFIG, "pubsub#title": "Test title push-D-1"))

            server.doTest iq, "got-message-pusher.example.org", cb, (msg) ->
                testConfigurationMessage "/user/push.1@enterprise.sf/status"

        , (cb) ->
            # Remote
            msg = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("configuration", node: "/user/push.3@ds9.sf/status")
                .cnode(server.makeForm("result", NS.PUBSUB_NODE_CONFIG, "pubsub#title": "Test title push-D-2"))

            server.doTest msg, "got-message-pusher.example.org", cb, (msg) ->
                testConfigurationMessage "/user/push.3@ds9.sf/status"
        ], done
# }}}
# {{{ new nodes
    it "should be notified of new nodes"
# }}}
# {{{ MAM
    it "should be able to MAM everything"
# }}}
# }}}
