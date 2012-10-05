async = require('async')
should = require('should')
{ NS, TestServer } = require('./test_server')

TestServer::makePublishIq = (from, to, id, node, atomOpts) ->
    return @makePubsubSetIq(from, to, id)
        .c("publish", node: node)
        .c("item", id: atomOpts.id)
        .cnode @makeAtom atomOpts

testPublishResultIq = (iq) ->
    iq.attrs.should.have.property "type", "result"
    itemEl = iq.getChild("pubsub", NS.PUBSUB)
        ?.getChild("publish")
        ?.getChild("item")
    should.exist itemEl
    itemEl.attrs.should.have.property "id"
    return itemEl.attrs.id

testErrorIq = (errType, childName, childNS = "urn:ietf:params:xml:ns:xmpp-stanzas") ->
    return (iq) ->
        iq.attrs.should.have.property "type", "error"
        errEl = iq.getChild "error"
        should.exist errEl
        errEl.attrs.should.have.property "type", errType
        should.exist errEl.getChild childName, childNS

describe "Posting", ->
    server = new TestServer()

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
                    should.exist pubsubEl

                    publishEl = pubsubEl.getChild "publish"
                    should.exist publishEl
                    publishEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    publishEl.children.should.have.length 1

                    itemEl = publishEl.getChild "item"
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id"
                    postId = itemEl.attrs.id
                    should.exist postId

            , (cb) ->
                # Fetch previously posted item from channel
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-A-1")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: postId)

                server.doTest iq, "got-iq-retrieve-A-1", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    pubsubEl = iq.getChild "pubsub", NS.PUBSUB
                    should.exist pubsubEl

                    itemsEl = pubsubEl.getChild "items"
                    should.exist itemsEl
                    itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    itemsEl.children.should.have.length 1

                    itemEl = itemsEl.getChild "item"
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id", postId
                    itemEl.children.should.have.length 1

                    entryEl = itemEl.getChild "entry", NS.ATOM
                    should.exist entryEl
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
                    should.exist entryEl
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
                    should.exist publishEl
                    publishEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"

                    itemEl = publishEl.getChild("item")
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id", "test-A-3"

            , (cb) ->
                # Publish to another channel with same ID
                publishEl = server.makePublishIq "data@enterprise.sf", "buddycloud.example.org",
                    "publish-A-4", "/user/data@enterprise.sf/posts", content: "Test post A3 bis", id: "test-A-3"

                server.doTest publishEl, "got-iq-publish-A-4", cb, (iq) ->
                    iq.attrs.should.have.property "type", "result"

                    publishEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("publish")
                    should.exist publishEl
                    publishEl.attrs.should.have.property "node", "/user/data@enterprise.sf/posts"

                    itemEl = publishEl.getChild("item")
                    should.exist itemEl
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
                    should.exist itemsEl
                    itemsEl.attrs.should.have.property "node", "/user/picard@enterprise.sf/posts"
                    itemEl = itemsEl.getChild "item"
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id"
                    should.exist itemEl.getChild "entry", NS.ATOM

            server.doTests publishEl, done, events


    describe "to a remote channel", ->
        it "must be submitted to the authoritative server", (done) ->
            publishEl = server.makePublishIq "picard@enterprise.sf", "buddycloud.example.org",
                "publish-C-1", "/user/sisko@ds9.sf/posts", content: "Test post C1"

            server.doTest publishEl, "got-iq-to-buddycloud.ds9.sf", done, (iq) ->
                iq.attrs.should.have.property "type", "set"
                pubsubEl = iq.getChild("pubsub", NS.PUBSUB)
                should.exist pubsubEl

                actorEl = pubsubEl.getChild("actor", NS.BUDDYCLOUD_V1)
                should.exist actorEl
                actorEl.getText().should.equal "picard@enterprise.sf"

                entryEl = pubsubEl.getChild("publish")
                    ?.getChild("item")
                    ?.getChild("entry", NS.ATOM)
                should.exist entryEl
                atom = server.parseAtom entryEl
                atom.should.have.property "content", "Test post C1"

        it "must be replicated locally", (done) ->
            entryEl = server.makeAtom content: "Test post C2", author: "sisko@ds9.sf", id: "test-C-2"
            msgEl = server.makePubsubEventMessage("buddycloud.ds9.sf", "buddycloud.example.org")
                .c("items", node: "/user/sisko@ds9.sf/posts")
                .c("item", id: "test-C-2")
                .cnode(entryEl)

            server.doTest msgEl, "got-message-picard@enterprise.sf/abc", done, (msg) ->
                msg.attrs.should.have.property "from", "buddycloud.example.org"
                itemsEl = msg.getChild("event", NS.PUBSUB_EVENT)
                    ?.getChild("items")
                should.exist itemsEl
                itemsEl.attrs.should.have.property "node", "/user/sisko@ds9.sf/posts"
                itemEl = itemsEl.getChild "item"
                should.exist itemEl
                itemEl.attrs.should.have.property "id", "test-C-2"
                should.exist itemEl.getChild "entry", NS.ATOM


    describe "a reply", ->
        it.skip "should succeed if the post exists", (done) ->

        it.skip "should fail if the post does not exist", (done) ->


    describe "an update", ->
        it.skip "should be possible for the author", (done) ->

        it.skip "should not be possible for anyone else", (done) ->

        it.skip "should not be possible for a deleted item", (done) ->


describe "Retracting", ->
    describe "a local item", ->
        it.skip "should be possible for the author", (done) ->

        it.skip "should be possible for the channel owner", (done) ->

        it.skip "should be possible for the channel moderator", (done) ->

        it.skip "should not be possible for anyone else", (done) ->

        it.skip "should replace the item with a tombstone", (done) ->

        it.skip "should be notified to subscribers", (done) ->

    describe "a remote item", ->
        it.skip "must be possible for authorized users", (done) ->
            # Submitted remotely

        it.skip "must not be possible for unauthorized users", (done) ->
            # Not submitted remotely

        it.skip "must be replicated locally", (done) ->
