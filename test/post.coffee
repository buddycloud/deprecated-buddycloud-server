async = require('async')
should = require('should')
moment = require('moment')
{ NS, TestServer } = require('./test_server')

# {{{ Helpers
testPublishResultIq = (iq) ->
    iq.attrs.should.have.property "type", "result"
    itemEl = iq.getChild("pubsub", NS.PUBSUB)
        ?.getChild("publish")
        ?.getChild("item")
    should.exist itemEl, "missing element: <item/>"
    itemEl.attrs.should.have.property "id"
    return itemEl.attrs.id

testErrorIq = (errType, childName, childNS = "urn:ietf:params:xml:ns:xmpp-stanzas") ->
    return (iq) ->
        iq.attrs.should.have.property "type", "error"
        errEl = iq.getChild "error"
        should.exist errEl, "missing element: <error/>"
        errEl.attrs.should.have.property "type", errType
        should.exist errEl.getChild(childName, childNS),
            "missing element: <#{childName} xmlns=\"#{childNS}\"/>, " +
            "got these instead: #{errEl.children}"

testTombstone = (tsEl, id) ->
    tsEl.attrs.should.have.property "ref"
    tsEl.attrs.should.have.property "when"

    upEd = tsEl.getChild "updated", NS.ATOM
    should.exist upEd, "missing element: <updated/>"
    upEd.getText().should.equal tsEl.attrs.when

    should.exist tsEl.getChild("published", NS.ATOM), "missing element: <published/>"

    idEl = tsEl.getChild "id", NS.ATOM
    should.exist idEl, "missing element: <id/>"
    idEl.getText().should.equal id

    linkEl = tsEl.getChild "link", NS.ATOM
    should.exist linkEl, "missing element: <link/>"
    linkEl.attrs.should.have.property "rel", "self"
    linkEl.attrs.should.have.property "href", tsEl.attrs.ref

    otEl = tsEl.getChild("object", NS.AS)?.getChild "object-type"
    should.exist otEl, "missing element: <object-type/>"
    otEl.getText().should.equal "note"

    verbEl = tsEl.getChild "verb", NS.AS
    should.exist verbEl, "missing element: <verb/>"
    verbEl.getText().should.equal "post"

    should.not.exist tsEl.getChild("author", NS.ATOM), "found element: <author/>"
    should.not.exist tsEl.getChild("content", NS.ATOM), "found element: <content/>"
# }}}
# {{{ Posting
describe "Posting", ->
    server = new TestServer()

    # {{{ to a channel
    describe "to a channel", ->
        it "must normalize Atoms", (done) ->
            postId = null

            async.series [(cb) ->
                # Post item to channel
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-A-1", "/user/picard@enterprise.sf/posts",
                    content: "Test post", author_uri: "dummy", published: "dummy", updated: "dummy"

                server.doTest publishEl, "got-iq-publish-A-1", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    pubsubEl = iq.getChild "pubsub", NS.PUBSUB
                    should.exist pubsubEl, "missing element: <pubsub/>"

                    publishEl = pubsubEl.getChild "publish"
                    should.exist publishEl, "missing element: <pubsub/>"
                    publishEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    publishEl.children.should.have.length 1

                    itemEl = publishEl.getChild "item"
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id"
                    postId = itemEl.attrs.id

            , (cb) ->
                # Fetch previously posted item from channel
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-A-1")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: postId)

                server.doTest iq, "got-iq-retrieve-A-1", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    pubsubEl = iq.getChild "pubsub", NS.PUBSUB
                    should.exist pubsubEl, "missing element: <pubsub/>"

                    itemsEl = pubsubEl.getChild "items"
                    should.exist itemsEl, "missing element: <items/>"
                    itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    itemsEl.children.should.have.length 1

                    itemEl = itemsEl.getChild "item"
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id", postId
                    itemEl.children.should.have.length 1

                    entryEl = itemEl.getChild "entry", NS.ATOM
                    should.exist entryEl, "missing element: <entry/>"
                    atom = server.parseAtom entryEl

                    expectedProperties =
                        author_uri: "acct:picard@enterprise.sf", content: "Test post",
                        id: postId, object: "note", verb: "post"
                    for name, val of expectedProperties
                        atom.should.have.property name, val

                    atom.should.have.property "link"
                    atom.should.not.have.property "in_reply_to"
                    atom.should.not.have.property "published", "dummy"
                    atom.should.not.have.property "updated", "dummy"

            , (cb) ->
                # Post reply to channel
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-A-2", "/user/picard@enterprise.sf/posts",
                    content: "Test reply", id: "reply-A-2", in_reply_to: postId

                server.doTest publishEl, "got-iq-publish-A-2", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
                    id = testPublishResultIq iq
                    id.should.equal "reply-A-2"

            , (cb) ->
                # Fetch reply from channel
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-A-2")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "reply-A-2")

                server.doTest iq, "got-iq-retrieve-A-2", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
                    entryEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChild("item")
                        ?.getChild("entry", NS.ATOM)
                    should.exist entryEl, "missing element: <entry/>"
                    atom = server.parseAtom entryEl

                    expectedProperties =
                        author_uri: "acct:picard@enterprise.sf", content: "Test reply",
                        id: "reply-A-2", in_reply_to: postId, object: "comment", verb: "comment"
                    for name, val of expectedProperties
                        atom.should.have.property name, val
                    for name in ["link", "published", "updated"]
                        atom.should.have.property name
            ], done

        it "must ensure that IDs are only unique within a node", (done) ->
            async.series [(cb) ->
                # Publish to a channel with ID test-A-3
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-A-3", "/user/picard@enterprise.sf/posts", content: "Test post A3", id: "test-A-3"

                server.doTest publishEl, "got-iq-publish-A-3", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    publishEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("publish")
                    should.exist publishEl, "missing element: <pubsub/>"
                    publishEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"

                    itemEl = publishEl.getChild("item")
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id", "test-A-3"

            , (cb) ->
                # Publish to another channel with same ID
                publishEl = server.makePublishIq "data@enterprise.sf", "buddycloud.example.org",
                    "publish-A-4", "/user/data@enterprise.sf/posts", content: "Test post A3 bis", id: "test-A-3"

                server.doTest publishEl, "got-iq-publish-A-4", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    publishEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("publish")
                    should.exist publishEl, "missing element: <publish/>"
                    publishEl.attrs.should.have.property "node", "/user/data@enterprise.sf/posts"

                    itemEl = publishEl.getChild("item")
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id", "test-A-3"
            ], done

        it "must fail if the node does not exist", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-A-5", "/user/random-red-shirt@enterprise.sf/posts", content: "Test post A5", id: "test-A-5"

            server.doTest publishEl, "got-iq-publish-A-5", done, testErrorIq "cancel", "item-not-found"

        it "must fail if the payload is not an Atom", (done) ->
            publishEl = server.makePubsubSetIq("picard@enterprise.sf", "buddycloud.example.org", "publish-A-6")
                .c("publish", node: "/user/picard@enterprise.sf/posts").c("item")
                .c("invalid-element").t("Test post A6")

            server.doTest publishEl, "got-iq-publish-A-6", done, testErrorIq "modify", "bad-request"
    # }}}
    # {{{ to a local channel
    describe "to a local channel", ->
        it "must be possible for its owner", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-B-1", "/user/picard@enterprise.sf/posts", content: "Test post B1"
            server.doTest publishEl, "got-iq-publish-B-1", done, testPublishResultIq

        it "must be possible for a publisher", (done) ->
            publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                "publish-B-2", "/user/picard@enterprise.sf/posts", content: "Test post B2"
            server.doTest publishEl, "got-iq-publish-B-2", done, testPublishResultIq

        it "must not be possible for a member if publishModel is 'publishers'", (done) ->
            publishEl = server.makePublishIq "data@enterprise.sf", "buddycloud.example.org",
                "publish-B-3", "/user/picard@enterprise.sf/posts", content: "Test post B3"
            server.doTest publishEl, "got-iq-publish-B-3", done, testErrorIq "auth", "forbidden"

        it "must be possible for a member if publishModel is 'subscribers'", (done) ->
            publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                "publish-B-4", "/user/data@enterprise.sf/posts", content: "Test post B4"
            server.doTest publishEl, "got-iq-publish-B-4", done, testPublishResultIq

        it "must not be possible for a non-member if publishModel is 'subscribers'", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-B-5", "/user/data@enterprise.sf/posts", content: "Test post B5"
            server.doTest publishEl, "got-iq-publish-B-5", done, testErrorIq "auth", "forbidden"

        it "must be possible for a non-member if publishModel is 'open'", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-B-6", "/user/laforge@enterprise.sf/posts", content: "Test post B6"
            server.doTest publishEl, "got-iq-publish-B-6", done, testPublishResultIq

        it "must not be possible for an outcast", (done) ->
            publishEl = server.makePublishIq "data@enterprise.sf", "buddycloud.example.org",
                "publish-B-7", "/user/riker@enterprise.sf/posts", content: "Test post B7"
            server.doTest publishEl, "got-iq-publish-B-7", done, testErrorIq "auth", "forbidden"

        it "must be notified to subscribers", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-B-8", "/user/picard@enterprise.sf/posts", content: "Test post B8"

            events = {}
            for sub in ["picard@enterprise.sf/abc", "buddycloud.ds9.sf",
                        "laforge@enterprise.sf/abc", "laforge@enterprise.sf/def"]
                events["got-message-#{sub}"] = (msg) ->
                    msg.attrs.should.have.property "from", "buddycloud.example.org"
                    itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
                        ?.getChild("items")
                    should.exist itemsEl, "missing element: <items/>"
                    itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    itemEl = itemsEl.getChild "item"
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id"
                    should.exist itemEl.getChild("entry", NS.ATOM), "missing element: <entry/>"

            server.doTests publishEl, done, events,
                ["got-message-riker@enterprise.sf/abc", "got-message-buddycloud.voyager.sf"]
    # }}}
    # {{{ from a remote service
    describe "from a remote service", ->
        it "must reject posts from non-authoritative services", (done) ->
            publishEl = server.makePublishIq "buddycloud.voyager.sf", "buddycloud.example.org",
                "publish-B-12", "/user/picard@enterprise.sf/posts",
                author: "sisko@ds9.sf", content: "Test post B12"
            publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("sisko@ds9.sf")

            server.doTest publishEl, "got-iq-publish-B-12", done, testErrorIq "modify", "bad-request"

        it "must reject remote posts with no or invalid <actor/>", (done) ->
            discoId = null

            async.series [(cb) ->
                # No actor
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-13", "/user/picard@enterprise.sf/posts",
                    author: "sisko@ds9.sf", content: "Test post B13"

                server.doTest publishEl, "got-iq-publish-B-13", cb, testErrorIq "modify", "bad-request"

            , (cb) ->
                # Invalid actor: correct server name
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-14", "/user/picard@enterprise.sf/posts",
                    author: "sisko@ds9.sf", content: "Test post B14"
                publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("buddycloud.ds9.sf")

                server.doTest publishEl, "got-iq-publish-B-14", cb, testErrorIq "modify", "bad-request"

            , (cb) ->
                # Invalid actor: incorrect server name
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-15", "/user/picard@enterprise.sf/posts",
                    author: "sisko@ds9.sf", content: "Test post B15"
                publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("buddycloud.voyager.sf")

                # This will also do a disco#items to buddycloud.voyager.sf, so tell the server how to respond to it
                server.disco.items["buddycloud.voyager.sf"] = []
                server.doTest publishEl, "got-iq-publish-B-15", cb, testErrorIq "modify", "bad-request"

            ], (err) ->
                # Cleanup first
                delete server.disco.items["buddycloud.voyager.sf"]
                done err

        it "must use <actor/> for the post author", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-16", "/user/picard@enterprise.sf/posts",
                    author_uri: "acct:odo@ds9.sf", content: "Test post B16", id: "test-B-16"
                publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("sisko@ds9.sf")

                server.doTest publishEl, "got-iq-publish-B-16", cb, testPublishResultIq

            , (cb) ->
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "publish-B-17")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-B-16")

                server.doTest iq, "got-iq-publish-B-17", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
                    entryEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChild("item")
                        ?.getChild("entry", NS.ATOM)
                    should.exist entryEl, "missing element: <entry/>"
                    atom = server.parseAtom entryEl
                    atom.should.have.property "author_uri", "acct:sisko@ds9.sf"
            ], done

        it "must check for permissions of remote posters", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-10", "/user/picard@enterprise.sf/posts",
                    author: "sisko@ds9.sf", content: "Test post B10"
                publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("sisko@ds9.sf")

                server.doTest publishEl, "got-iq-publish-B-10", cb, testPublishResultIq

            , (cb) ->
                publishEl = server.makePublishIq "buddycloud.ds9.sf", "buddycloud.example.org",
                    "publish-B-11", "/user/picard@enterprise.sf/posts",
                    author: "odo@ds9.sf", content: "Test post B11"
                publishEl.up().up().up().c("actor", xmlns: NS.BUDDYCLOUD_V1).t("odo@ds9.sf")

                server.doTest publishEl, "got-iq-publish-B-11", cb, testErrorIq "auth", "forbidden"
            ], done
    # }}}
    # {{{ to a remote channel
    describe "to a remote channel", ->
        it "must be submitted to the authoritative server", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-C-1", "/user/sisko@ds9.sf/posts", content: "Test post C1"

            server.doTest publishEl, "got-iq-to-buddycloud.ds9.sf", done, (iq) ->
                iq.attrs.should.have.property "type", "set"
                pubsubEl = iq.getChild("pubsub", NS.PUBSUB)
                should.exist pubsubEl, "missing element: <pubsub/>"

                actorEl = pubsubEl.getChild("actor", NS.BUDDYCLOUD_V1)
                should.exist actorEl, "missing element: <actor/>"
                actorEl.getText().should.equal "picard@enterprise.sf"

                entryEl = pubsubEl.getChild("publish")
                    ?.getChild("item")
                    ?.getChild("entry", NS.ATOM)
                should.exist entryEl, "missing element: <entry/>"
                atom = server.parseAtom entryEl
                atom.should.have.property "content", "Test post C1"

        it "must be replicated locally", (done) ->
            entryEl = server.makeAtom content: "Test post C2", author_uri: "acct:sisko@ds9.sf", id: "test-C-2"
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("items", node: "/user/sisko@ds9.sf/posts")
                .c("item", id: "test-C-2")
                .cnode(entryEl)

            server.doTest msgEl, "got-message-picard@enterprise.sf/abc", done, (msg) ->
                msg.attrs.should.have.property "from", "buddycloud.example.org"
                itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
                    ?.getChild("items")
                should.exist itemsEl, "missing element: <items/>"
                itemsEl.attrs.should.have.property "node", "/user/sisko@ds9.sf/posts"
                itemEl = itemsEl.getChild "item"
                should.exist itemEl, "missing element: <item/>"
                itemEl.attrs.should.have.property "id", "test-C-2"
                should.exist itemEl.getChild("entry", NS.ATOM), "missing element: <entry/>"

        it "must not be replicated if the Atom is invalid", (done) ->
            # The minimum we need for items is author/uri, content, published, updated and id.
            msgs = [
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-4")
                    .cnode(server.makeAtom(content: "Test post C4", author_uri: "acct:sisko@ds9.sf", id: "test-C-4")
                        .getChild("author").remove("uri").root()),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-5")
                    .cnode(server.makeAtom(content: "Test post C5", author_uri: "acct:sisko@ds9.sf", id: "test-C-5")
                        .remove("content")),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-6")
                    .cnode(server.makeAtom(content: "Test post C6", author_uri: "acct:sisko@ds9.sf", id: "test-C-6")
                        .remove("published")),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-7")
                    .cnode(server.makeAtom(content: "Test post C7", author_uri: "acct:sisko@ds9.sf", id: "test-C-7")
                        .remove("updated")),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-8")
                    .cnode(server.makeAtom(content: "Test post C8", author_uri: "acct:sisko@ds9.sf", id: "test-C-8")
                        .remove("id")),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-9")
                    .cnode(server.makeAtom(content: "Test post C9", author_uri: "acct:sisko@ds9.sf", id: "test-C-9", published: "not a date")),
                server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/sisko@ds9.sf/posts")
                    .c("item", id: "test-C-10")
                    .cnode(server.makeAtom(content: "Test post C10", author_uri: "acct:sisko@ds9.sf", id: "test-C-10", updated: "not a date")),
            ]
            async.series [(cb) ->
                for msgEl in msgs
                    server.emit "stanza", msgEl.root()
                setTimeout cb, 500

            , (cb) ->
                async.forEach [4..10], (i, cb2) ->
                    iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-C-#{i}")
                        .c("items", node: "/user/sisko@ds9.sf/posts")
                        .c("item", id: "test-C-#{i}")

                    server.doTest iq, "got-iq-retrieve-C-#{i}", cb2, testErrorIq "cancel", "item-not-found"
                , cb
            ], done

        it "must not be replicated if the sender is not authoritative", (done) ->
            async.series [(cb) ->
                entryEl = server.makeAtom content: "Test post C3", author: "picard@enterprise.sf", id: "test-C-3"
                msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-C-3")
                    .cnode(entryEl)
                server.emit "stanza", msgEl.root()
                setTimeout cb, 250

            , (cb) ->
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-C-3")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-C-3")

                server.doTest iq, "got-iq-retrieve-C-3", cb, testErrorIq "cancel", "item-not-found"
            ], (done)
    # }}}
    # {{{ a reply
    describe "a reply", ->
        it "should succeed if the post exists", (done) ->
            async.series [(cb) ->
                # Publish a post
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-D-1", "/user/picard@enterprise.sf/posts", content: "Test post D1", id: "test-D-1"

                server.doTest publishEl, "got-iq-publish-D-1", cb, testPublishResultIq

            , (cb) ->
                # Publish a reply to the previous post
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-D-2", "/user/picard@enterprise.sf/posts",
                    content: "Test reply D1", id: "test-D-2", in_reply_to: "test-D-1"

                server.doTest publishEl, "got-iq-publish-D-2", cb, testPublishResultIq

            , (cb) ->
                # Fetch the reply to see how it was normalized
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-D-3")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-D-2")

                server.doTest iq, "got-iq-retrieve-D-3", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    entryEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChild("item")
                        ?.getChild("entry", NS.ATOM)
                    should.exist entryEl, "missing element: <entry/>"
                    atom = server.parseAtom entryEl

                    expectedProperties =
                        id: "test-D-2", in_reply_to: "test-D-1"
                        object: "comment", verb: "comment"
                    for name, val of expectedProperties
                        atom.should.have.property name, val
            ], done

        it "should fail if the post does not exist", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-D-4", "/user/picard@enterprise.sf/posts",
                content: "Test reply D4", id: "test-D-4", in_reply_to: "missing-post"

            server.doTest publishEl, "got-iq-publish-D-4", done, testErrorIq "modify", "not-acceptable"
    # }}}
    # {{{ an update
    describe "an update", ->
        it "should be possible for the author", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "publish-E-1", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post E1", id: "test-E-1"
                server.doTest publishEl, "got-iq-publish-E-1", cb, testPublishResultIq

            , (cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "publish-E-2", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Updated post E1", id: "test-E-1"
                server.doTest publishEl, "got-iq-publish-E-2", cb, testPublishResultIq

            ,(cb) ->
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-E-3")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-E-1")
                server.doTest iq, "got-iq-retrieve-E-3", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    entryEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChild("item")
                        ?.getChild("entry", NS.ATOM)
                    should.exist entryEl, "missing element: <entry/>"
                    atom = server.parseAtom entryEl

                    atom.should.have.property "author", "laforge@enterprise.sf"
                    atom.should.have.property "content", "Updated post E1"
                    atom.should.have.property "published"
                    atom.should.have.property "updated"
                    atom.published.should.not.equal atom.updated
            ], done

        it "should not be possible for anyone else", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "publish-E-4", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post E4", id: "test-E-4"
                server.doTest publishEl, "got-iq-publish-E-4", cb, testPublishResultIq

            , (cb) ->
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-5", "/user/picard@enterprise.sf/posts",
                    author: "laforge@ds9.sf", content: "Updated post E1", id: "test-E-4"
                server.doTest publishEl, "got-iq-publish-E-5", cb, testErrorIq "auth", "forbidden"
            ], done

        it "should not be possible for a deleted item", (done) ->
            async.series [(cb) ->
                # Publish
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-6", "/user/picard@enterprise.sf/posts",
                    content: "Test post E6", id: "test-E-6"
                server.doTest publishEl, "got-iq-publish-E-6", cb, testPublishResultIq

            , (cb) ->
                # Retract
                retEl = server.makePubsubSetIq("picard@enterprise.sf", "buddycloud.example.org", "publish-E-7")
                    .c("retract", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-E-6")
                server.doTest retEl, "got-iq-publish-E-7", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

            , (cb) ->
                # Update
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-8", "/user/picard@enterprise.sf/posts",
                    content: "Updated test post E6", id: "test-E-6"
                server.doTest publishEl, "got-iq-publish-E-8", cb, testErrorIq "modify", "not-acceptable"
            ], done

        it "should be possible for replies", (done) ->
            async.series [(cb) ->
                # Publish E18
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-18", "/user/picard@enterprise.sf/posts",
                    content: "Test post E18", id: "test-E-18"
                server.doTest publishEl, "got-iq-publish-E-18", cb, testPublishResultIq

            , (cb) ->
                # Publish E19 as reply to E18
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-19", "/user/picard@enterprise.sf/posts",
                    content: "Test reply E19", id: "test-E-19", in_reply_to: "test-E-18"
                server.doTest publishEl, "got-iq-publish-E-19", cb, testPublishResultIq

            , (cb) ->
                # Update E19
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-20", "/user/picard@enterprise.sf/posts",
                    content: "Updated test reoply E19", id: "test-E-19", in_reply_to: "test-E-18"
                server.doTest publishEl, "got-iq-publish-E-20", cb, testPublishResultIq
            ], done

        it "should not allow adding an <in-reply-to/>", (done) ->
            async.series [(cb) ->
                # Publish E9
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-9", "/user/picard@enterprise.sf/posts",
                    content: "Test post E9", id: "test-E-9"
                server.doTest publishEl, "got-iq-publish-E-9", cb, testPublishResultIq

            , (cb) ->
                # Publish E10
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-10", "/user/picard@enterprise.sf/posts",
                    content: "Test post E10", id: "test-E-10"
                server.doTest publishEl, "got-iq-publish-E-10", cb, testPublishResultIq

            , (cb) ->
                # Update E10 to be in-reply-to E9
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-11", "/user/picard@enterprise.sf/posts",
                    content: "Updated test post E10", id: "test-E-10", in_reply_to: "test-E-9"
                server.doTest publishEl, "got-iq-publish-E-11", cb, testErrorIq "modify", "not-acceptable"
            ], done

        it "should not allow changing <in-reply-to/>", (done) ->
            async.series [(cb) ->
                # Publish E12
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-12", "/user/picard@enterprise.sf/posts",
                    content: "Test post E12", id: "test-E-12"
                server.doTest publishEl, "got-iq-publish-E-12", cb, testPublishResultIq

            , (cb) ->
                # Publish E13
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-13", "/user/picard@enterprise.sf/posts",
                    content: "Test post E13", id: "test-E-13"
                server.doTest publishEl, "got-iq-publish-E-13", cb, testPublishResultIq

            , (cb) ->
                # Publish E14 as reply to E13
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-14", "/user/picard@enterprise.sf/posts",
                    content: "Test post E14", id: "test-E-14", in_reply_to: "test-E-13"
                server.doTest publishEl, "got-iq-publish-E-14", cb, testPublishResultIq

            , (cb) ->
                # Update E14 to be in-reply-to E12
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-15", "/user/picard@enterprise.sf/posts",
                    content: "Updated test post E14", id: "test-E-14", in_reply_to: "test-E-12"
                server.doTest publishEl, "got-iq-publish-E-15", cb, testErrorIq "modify", "not-acceptable"
            ], done

        it "should not allow removing <in-reply-to/>", (done) ->
            async.series [(cb) ->
                # Publish E16
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-16", "/user/picard@enterprise.sf/posts",
                    content: "Test post E16", id: "test-E-16"
                server.doTest publishEl, "got-iq-publish-E-16", cb, testPublishResultIq

            , (cb) ->
                # Publish E17 as reply to E16
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-17", "/user/picard@enterprise.sf/posts",
                    content: "Test post E17", id: "test-E-17", in_reply_to: "test-E-16"
                server.doTest publishEl, "got-iq-publish-E-17", cb, testPublishResultIq

            , (cb) ->
                # Update E17 to not be a reply
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "publish-E-18", "/user/picard@enterprise.sf/posts",
                    content: "Updated test post E17", id: "test-E-17"
                server.doTest publishEl, "got-iq-publish-E-18", cb, testErrorIq "modify", "not-acceptable"
            ], done
    # }}}
# }}}
# {{{ Retrieving posts
describe "Retrieving posts", ->
    server = new TestServer()

    testPostAndRetrieve = (channel, postAuthor, id, retrieveJid, cb_done, cb_check) ->
        node = "/user/#{channel}/posts"
        unless cb_check?
            cb_check = (iq) ->
                iq.attrs.should.have.property "type", "result"

                itemsEl = iq.getChild("pubsub", NS.PUBSUB)
                    ?.getChild("items")
                should.exist itemsEl, "missing element: <items/>"
                itemsEl.attrs.should.have.property "node", node

                itemEl = itemsEl.getChild "item"
                should.exist itemEl, "missing element: <item/>"
                itemEl.attrs.should.have.property "id", "test-#{id}"

                entryEl = itemEl.getChild "entry", NS.ATOM
                should.exist entryEl, "missing element: <entry/>"
                atom = server.parseAtom entryEl

                expectedProperties =
                    author_uri: "acct:#{postAuthor}", content: "Test post #{id}",
                    id: "test-#{id}", object: "note", verb: "post"
                for name, val of expectedProperties
                    atom.should.have.property name, val

        async.series [(cb) ->
            publishEl = server.makePublishIq postAuthor, "buddycloud.example.org",
                "publish-#{id}", node,
                content: "Test post #{id}", id: "test-#{id}"
            server.doTest publishEl, "got-iq-publish-#{id}", cb, testPublishResultIq
        , (cb) ->
            iq = server.makePubsubGetIq(retrieveJid, "buddycloud.example.org", "retrieve-#{id}")
                .c("items", node: node)
                .c("item", id: "test-#{id}")
            server.doTest iq, "got-iq-retrieve-#{id}", cb, cb_check
        ], cb_done

    it "must be possible for anyone in an open channel", (done) ->
        testPostAndRetrieve "picard@enterprise.sf", "picard@enterprise.sf", "H-1",
            "riker@enterprise.sf", done

    it "must be possible for susbcribers of private channels", (done) ->
        testPostAndRetrieve "data@enterprise.sf", "data@enterprise.sf", "H-2",
            "laforge@enterprise.sf", done

    it "must not be possible for non-members of private channels", (done) ->
        testPostAndRetrieve "data@enterprise.sf", "data@enterprise.sf", "H-3",
            "riker@enterprise.sf", done, testErrorIq "auth", "forbidden"

    it "must not be possible for an outcast", (done) ->
        testPostAndRetrieve "riker@enterprise.sf", "riker@enterprise.sf", "H-4",
            "data@enterprise.sf", done, testErrorIq "auth", "forbidden"

    # Once again, test skipped because the server returns "not-implemented"
    # instead of "not-acceptable"...
    it.skip "must fail if node is missing", (done) ->
        iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-H-5")
            .c("items")
            .c("item", id: "bogus-id")
        server.doTest iq, "got-iq-retrieve-H-5", done, testErrorIq "modify", "not-acceptable"

    it "must return all items if <item/> is missing", (done) ->
        async.series [(cb) ->
            # Make sure there's at least one item if used with "it.only" :)
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-6", "/user/picard@enterprise.sf/posts",
                content: "Test post H6", id: "test-H-6"
            server.doTest publishEl, "got-iq-publish-H-6", cb, testPublishResultIq

        , (cb) ->
            iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-H-6")
                .c("items", node: "/user/picard@enterprise.sf/posts")

            server.doTest iq, "got-iq-retrieve-H-6", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"
                items = iq.getChild("pubsub", NS.PUBSUB)
                    ?.getChild("items")
                    ?.getChildren("item")
                should.exist items, "missing element: <item/>"
                itemIds = []
                for itemEl in items
                    itemEl.attrs.should.have.property "id"
                    itemIds.push itemEl.attrs.id
                itemIds.should.include "test-H-6"
        ], done

    it "must work for several items", (done) ->
        async.series [(cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-7", "/user/picard@enterprise.sf/posts",
                content: "Test post H7", id: "test-H-7"
            server.doTest publishEl, "got-iq-publish-H-7", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-8", "/user/picard@enterprise.sf/posts",
                content: "Test post H8", id: "test-H-8"
            server.doTest publishEl, "got-iq-publish-H-8", cb, testPublishResultIq

        , (cb) ->
                # Check that both items were actually deleted
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-H-9")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-H-7")
                    .up().c("item", id: "test-H-8")

                server.doTest iq, "got-iq-retrieve-H-9", cb, (iq) ->
                    items = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChildren("item")
                    should.exist items, "missing element: <item/>"
                    itemIds = []
                    for itemEl in items
                        itemEl.attrs.should.have.property "id"
                        itemIds.push itemEl.attrs.id

                        entry = itemEl.getChild "entry", NS.ATOM
                        should.exist entry, "missing element: <entry/>"
                        atom = server.parseAtom entry
                        atom.should.have.property "id", itemEl.attrs.id

                    itemIds.should.eql ["test-H-7", "test-H-8"]
            ], done

    it "must work for recent items requests", (done) ->
        @timeout 4000
        async.series [(cb) ->
            publishEl = server.makePublishIq "riker@enterprise.sf", "buddycloud.example.org",
                "publish-H-10", "/user/riker@enterprise.sf/posts",
                content: "Test post H10", id: "test-H-10"
            server.doTest publishEl, "got-iq-publish-H-10", cb, testPublishResultIq
        , (cb) ->
            # Make sure we don't catch older messages by accident
            setTimeout cb, 1200
        , (cb) =>
            @since = moment.utc().format()
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-11", "/user/picard@enterprise.sf/posts",
                content: "Test post H11", id: "test-H-11"
            server.doTest publishEl, "got-iq-publish-H-11", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-12", "/user/picard@enterprise.sf/posts",
                content: "Test post H12", id: "test-H-12"
            server.doTest publishEl, "got-iq-publish-H-12", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "riker@enterprise.sf", "buddycloud.example.org",
                "publish-H-13", "/user/riker@enterprise.sf/posts",
                content: "Test post H13", id: "test-H-13"
            server.doTest publishEl, "got-iq-publish-H-13", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "data@enterprise.sf", "buddycloud.example.org",
                "publish-H-14", "/user/data@enterprise.sf/posts",
                content: "Test post H14", id: "test-H-14"
            server.doTest publishEl, "got-iq-publish-H-14", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "riker@enterprise.sf", "buddycloud.example.org",
                "publish-H-15", "/user/riker@enterprise.sf/status",
                content: "Test post H15", id: "test-H-15"
            server.doTest publishEl, "got-iq-publish-H-15", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-16", "/user/picard@enterprise.sf/posts",
                content: "Test post H16", id: "test-H-16"
            server.doTest publishEl, "got-iq-publish-H-16", cb, testPublishResultIq

        , (cb) =>
            # Query recent items
            iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-H-17")
                .c("recent-items", xmlns: NS.BUDDYCLOUD_V1, since: @since, max: 2)

            server.doTest iq, "got-iq-retrieve-H-17", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"
                pubsubEl = iq.getChild "pubsub", NS.PUBSUB
                should.exist pubsubEl, "missing element: <pubsub/>"

                gotNodes = []
                gotItems = []
                for items in pubsubEl.getChildren("items")
                    items.attrs.should.have.property "node"
                    node = items.attrs.node
                    unless node in gotNodes
                        gotNodes.push node
                    for item in items.children
                        item.attrs.should.have.property "id"
                        gotItems.push item.attrs.id

                # Picard: there should be H-16 and H-12 (H-11 is too much).
                # Riker: there should be H-13 but not H-10 (too old).
                # H-14 (Data) and H-15 (/status) should not be there.
                # Items should be sorted by decreasing ID.
                gotNodes.should.eql ["/user/picard@enterprise.sf/posts", "/user/riker@enterprise.sf/posts"]
                gotItems.should.eql ["test-H-16", "test-H-13", "test-H-12"]
        ], done

    it "must work for replies requests for existing posts", (done) ->
        async.series [(cb) ->
            publishEl = server.makePublishIq "riker@enterprise.sf", "buddycloud.example.org",
                "publish-H-18", "/user/riker@enterprise.sf/posts",
                content: "Test post H18", id: "test-H-18"
            server.doTest publishEl, "got-iq-publish-H-18", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-19", "/user/riker@enterprise.sf/posts",
                content: "Test reply H19", id: "test-H-19", in_reply_to: "test-H-18"
            server.doTest publishEl, "got-iq-publish-H-19", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-20", "/user/riker@enterprise.sf/posts",
                content: "Test post H20", id: "test-H-20"
            server.doTest publishEl, "got-iq-publish-H-20", cb, testPublishResultIq
        , (cb) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-H-21", "/user/riker@enterprise.sf/posts",
                content: "Test reply H21", id: "test-H-21", in_reply_to: "test-H-18"
            server.doTest publishEl, "got-iq-publish-H-21", cb, testPublishResultIq

        , (cb) ->
            # Retrieve replies to test-H-18
            iq = server.makePubsubGetIq("laforge@enterprise.sf", "buddycloud.example.org", "retrieve-H-22")
                .c("replies", xmlns: NS.BUDDYCLOUD_V1, node: "/user/riker@enterprise.sf/posts", item_id: "test-H-18")

            server.doTest iq, "got-iq-retrieve-H-22", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"
                pubsubEl = iq.getChild "pubsub", NS.PUBSUB
                should.exist pubsubEl, "missing element: <pubsub/>"

                itemsEl = pubsubEl.getChild "items"
                should.exist itemsEl, "missing element: <items/>"

                ids = []
                for item in itemsEl.getChildren("item")
                    item.attrs.should.have.property "id"
                    ids.push item.attrs.id

                ids.should.eql ["test-H-21", "test-H-19"]
        ], done

    it "must fail for replies requests for missing posts", (done) ->
        iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-H-23")
            .c("replies", xmlns: NS.BUDDYCLOUD_V1, node: "/user/picard@enterprise.sf/posts", item_id: "missing-post-H-23")
            server.doTest iq, "got-iq-retrieve-H-23", done,
                testErrorIq "cancel", "item-not-found"
# }}}
# {{{ Retracting
describe "Retracting", ->
    server = new TestServer()
    retractIq = (from, to, id, node, itemIds...) ->
        iq = server.makePubsubSetIq(from, to, id)
            .c("retract", node: node)
        for itemId in itemIds
            iq.c("item", id: itemId)
        return iq.root()

    # {{{ a local item
    describe "a local item", ->
        it "should be possible for the author", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-1", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F1", id: "test-F-1"
                server.doTest publishEl, "got-iq-retract-F-1", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-2", "/user/picard@enterprise.sf/posts", "test-F-1"
                server.doTest retEl, "got-iq-retract-F-2", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            ], done

        it "should be possible for an owner", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-3", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F3", id: "test-F-3"
                server.doTest publishEl, "got-iq-retract-F-3", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org",
                    "retract-F-4", "/user/picard@enterprise.sf/posts", "test-F-3"
                server.doTest retEl, "got-iq-retract-F-4", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            ], done

        it "should be possible for a moderator", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "riker@enterprise.sf", "buddycloud.example.org",
                    "retract-F-5", "/user/riker@enterprise.sf/posts",
                    author: "riker@enterprise.sf", content: "Test post F5", id: "test-F-5"
                server.doTest publishEl, "got-iq-retract-F-5", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org",
                    "retract-F-6", "/user/riker@enterprise.sf/posts", "test-F-5"
                server.doTest retEl, "got-iq-retract-F-6", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            ], done

        it "should not be possible for anyone else", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-7", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F7", id: "test-F-7"
                server.doTest publishEl, "got-iq-retract-F-7", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "data@enterprise.sf", "buddycloud.example.org",
                    "retract-F-8", "/user/picard@enterprise.sf/posts", "test-F-7"
                server.doTest retEl, "got-iq-retract-F-8", cb, testErrorIq "auth", "forbidden"
            ], done

        it "should replace the item with a tombstone", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-9", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F9", id: "test-F-9"
                server.doTest publishEl, "got-iq-retract-F-9", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-10", "/user/picard@enterprise.sf/posts", "test-F-9"
                server.doTest retEl, "got-iq-retract-F-10", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            , (cb) ->
                iq = server.makePubsubGetIq("laforge@enterprise.sf", "buddycloud.example.org", "retract-F-11")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-F-9")

                server.doTest iq, "got-iq-retract-F-11", cb, (iq) ->
                    itemEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChild("item")
                    should.exist itemEl, "missing element: <item/>"
                    itemEl.attrs.should.have.property "id", "test-F-9"

                    tsEl = itemEl.getChild "deleted-entry", NS.TS
                    should.exist tsEl, "missing element: <deleted-entry/>"
                    testTombstone tsEl, "test-F-9"
            ], done

        it "should fail if the item does not exist", (done) ->
            retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org",
                "retract-F-14", "/user/picard@enterprise.sf/posts", "missing-post"

            server.doTest retEl, "got-iq-retract-F-14", done, testErrorIq "cancel", "item-not-found"

        # Skip this test. It fails because the server responds with
        # "not-implemented" instead of "bad-request", but it's good enough....
        it.skip "should fail if the node is missing", (done) ->
            retEl = server.makePubsubSetIq("picard@enterprise.sf", "buddycloud.example.org", "retract-F-15")
                .c("retract")
                .c("item", id: "bogus-id")

            server.doTest retEl, "got-iq-retract-F-15", done, testErrorIq "modify", "bad-request"

        # Skip this test. It fails because the server responds with
        # "not-implemented" instead of "bad-request", but it's good enough....
        it.skip "should fail if the item ID is missing", (done) ->
            retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org",
                "retract-F-16", "/user/picard@enterprise.sf/posts"

            server.doTest retEl, "got-iq-retract-F-16", done, testErrorIq "modify", "bad-request"

        it "should support several item IDs", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-17", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F17", id: "test-F-17"
                server.doTest publishEl, "got-iq-retract-F-17", cb, testPublishResultIq

            , (cb) ->
                publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                    "retract-F-18", "/user/picard@enterprise.sf/posts",
                    author: "picard@enterprise.sf", content: "Test post F18", id: "test-F-18"
                server.doTest publishEl, "got-iq-retract-F-18", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org", "retract-F-19",
                    "/user/picard@enterprise.sf/posts", "test-F-17", "test-F-18"

                server.doTest retEl, "got-iq-retract-F-19", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

            , (cb) ->
                # Check that both items were actually deleted
                iq = server.makePubsubGetIq("laforge@enterprise.sf", "buddycloud.example.org", "retract-F-20")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "test-F-17")
                    .up().c("item", id: "test-F-18")

                server.doTest iq, "got-iq-retract-F-20", cb, (iq) ->
                    items = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("items")
                        ?.getChildren("item")
                    should.exist items, "missing element: <item/>"
                    itemIds = []
                    for itemEl in items
                        itemEl.attrs.should.have.property "id"
                        itemIds.push itemEl.attrs.id

                        tsEl = itemEl.getChild "deleted-entry", NS.TS
                        should.exist tsEl, "missing element: <deleted-entry/>"
                        testTombstone tsEl, itemEl.attrs.id

                    itemIds.should.eql ["test-F-17", "test-F-18"]
            ], done

        it "should be notified to subscribers", (done) ->
            async.series [(cb) ->
                publishEl = server.makePublishIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-12", "/user/picard@enterprise.sf/posts",
                    author: "laforge@enterprise.sf", content: "Test post F12", id: "test-F-12"
                server.doTest publishEl, "got-iq-retract-F-12", cb, testPublishResultIq

            , (cb) ->
                retEl = retractIq "laforge@enterprise.sf", "buddycloud.example.org",
                    "retract-F-13", "/user/picard@enterprise.sf/posts", "test-F-12"
                events =
                    "got-iq-retract-F-13": (iq) ->
                        iq.attrs.should.have.property "type", "result"

                for sub in ["picard@enterprise.sf/abc", "buddycloud.ds9.sf",
                            "laforge@enterprise.sf/abc", "laforge@enterprise.sf/def"]
                    events["got-message-#{sub}"] = (msg) ->
                        msg.attrs.should.have.property "from", "buddycloud.example.org"
                        itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
                            ?.getChild("items")
                        should.exist itemsEl, "missing element: <items/>"
                        itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"

                        retEl = itemsEl.getChild "retract"
                        should.exist retEl, "missing element: <retract/>"
                        retEl.attrs.should.have.property "id", "test-F-12"

                        itemEl = itemsEl.getChild "item"
                        should.exist itemEl, "missing element: <item/>"
                        itemEl.attrs.should.have.property "id"
                        tsEl = itemEl.getChild "deleted-entry", NS.TS
                        should.exist tsEl, "missing element: <deleted-entry/>"
                        testTombstone tsEl, "test-F-12"

                server.doTests retEl, cb, events,
                    ["got-message-riker@enterprise.sf/abc", "got-message-buddycloud.voyager.sf"]
            ], done
    # }}}
    # {{{ a remote item
    describe "a remote item", ->
        it "must be submitted to the remote service", (done) ->
            retEl = retractIq "picard@enterprise.sf", "buddycloud.example.org",
                "retract-G-1", "/user/sisko@ds9.sf/posts", "test-G-1"

            server.doTest retEl, "got-iq-to-buddycloud.ds9.sf", done, (iq) ->
                iq.attrs.should.have.property "type", "set"

                actorEl = iq.getChild("pubsub", NS.PUBSUB)
                    ?.getChild("actor", NS.BUDDYCLOUD_V1)
                should.exist actorEl, "missing element: <actor/>"
                actorEl.getText().should.equal "picard@enterprise.sf"

                retractEl = iq.getChild("pubsub", NS.PUBSUB)
                    ?.getChild("retract")
                should.exist retractEl, "missing element: <retract/>"
                retractEl.attrs.should.have.property "node", "/user/sisko@ds9.sf/posts"
                itemEl = retractEl.getChild "item"
                should.exist itemEl, "missing element: <item/>"
                itemEl.attrs.should.have.property "id", "test-G-1"
    # }}}
# }}}
