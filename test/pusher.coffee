async = require('async')
should = require('should')
{ NS, TestServer } = require('./test_server')

# {{{ Helpers
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

testSubscription = (server, el, done, node, jid, subscription="subscribed") ->
    gotSub = false
    gotItem = subscription is "pending" # no item for pending subscriptions
    nodeUser = /^\/user\/([^\/]+)\/?(.*)/.exec(node)[1]

    cb = (err) ->
        clearTimeout timeout
        server.removeAllListeners "got-message-pusher.example.org"
        done err

    timeout = setTimeout ->
        cb new Error "gotSub: #{gotSub}, gotItem: #{gotItem}"
    , 1000

    server.on "got-message-pusher.example.org", (msg) ->
        msg.attrs.should.have.property "from", "buddycloud.example.org"
        evEl = msg.getChild "event", NS.PUBSUB_EVENT
        should.exist evEl, "missing element: <event/>"

        subEl = evEl.getChild "subscription"
        itemsEl = evEl.getChild "items"
        if subEl?
            subEl.attrs.should.have.property "node", node
            subEl.attrs.should.have.property "jid", jid
            subEl.attrs.should.have.property "subscription", subscription
            gotSub = true
        if itemsEl?
            should.exist itemsEl, "missing element: <items/>"
            itemsEl.attrs.should.have.property "node", "/user/#{jid}/subscriptions"

            itemEl = itemsEl.getChild "item"
            should.exist itemEl, "missing element: <item/>"
            itemEl.attrs.should.have.property "id", nodeUser

            qEl = itemEl.getChild("query", NS.DISCO_ITEMS)
            should.exist qEl, "missing element: <query/>"
            gotItem = true
        if not subEl? and not itemsEl?
            cb new Error "<message/> without <subscription/> nor <items/>"

        if gotSub and gotItem
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
    it "should be notified of new subscriptions", (done) ->
        async.series [(cb) ->
            # Local subscription
            iq = server.makePubsubSetIq("push.1@enterprise.sf/abc", "buddycloud.example.org", "push-B-1")
                .c("subscribe", node: "/user/push.2@enterprise.sf/posts", jid: "push.1@enterprise.sf")

            testSubscription server, iq, cb, "/user/push.2@enterprise.sf/posts", "push.1@enterprise.sf"

        , (cb) ->
            # Remote subscription
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("subscription", node: "/user/push.1@ds9.sf/posts", jid: "push.2@ds9.sf", subscription: "subscribed")

            testSubscription server, msgEl, cb, "/user/push.1@ds9.sf/posts", "push.2@ds9.sf"
        ], done

    it "should be notified of pending subscriptions", (done) ->
        async.series [(cb) ->
            # Local subscription to a private channel
            iq = server.makePubsubSetIq("push.1@enterprise.sf", "buddycloud.example.org", "push-B-2")
                .c("subscribe", node: "/user/data@enterprise.sf/posts", jid: "push.1@enterprise.sf")

            testSubscription server, iq, cb, "/user/data@enterprise.sf/posts", "push.1@enterprise.sf", "pending"

        , (cb) ->
            # FIXME: should this even be notified?
            # Remote subscription to a private channel
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("subscription", node: "/user/push.2@ds9.sf/posts", jid: "push.1@ds9.sf", subscription: "pending")

            testSubscription server, msgEl, cb, "/user/push.2@ds9.sf/posts", "push.1@ds9.sf", "pending"
        ], done
# }}}
    it "should be notified of new nodes"
    it "should be able to MAM everything"
# }}}
