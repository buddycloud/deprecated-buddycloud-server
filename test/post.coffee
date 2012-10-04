async = require('async')
should = require('should')
{ NS, TestServer } = require('./test_server')

TestServer::makePublishIq = (from, to, id, node, atomOpts) ->
    return @makePubsubSetIq(from, to, id)
        .c("publish", node: node)
        .c("item", id: atomOpts.id)
        .cnode @makeAtom atomOpts

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

                server.doTest publishEl, "got-iq-result-publish-A-1", cb, (iq) ->
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

                server.doTest iq, "got-iq-result-retrieve-A-1", cb, (iq) ->
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

                server.doTest publishEl, "got-iq-result-publish-A-2", cb, (iq) ->
                    itemEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("publish")
                        ?.getChild("item")
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id", "reply-A-2"

            , (cb) ->
                # Fetch reply from channel
                iq = server.makePubsubGetIq("picard@enterprise.sf", "buddycloud.example.org", "retrieve-A-2")
                    .c("items", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "reply-A-2")

                server.doTest iq, "got-iq-result-retrieve-A-2", cb, (iq) ->
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

                server.doTest publishEl, "got-iq-result-publish-A-3", cb, (iq) ->
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

                server.doTest publishEl, "got-iq-result-publish-A-4", cb, (iq) ->
                    publishEl = iq.getChild("pubsub", NS.PUBSUB)
                        ?.getChild("publish")
                    should.exist publishEl
                    publishEl.attrs.should.have.property "node", "/user/data@enterprise.sf/posts"

                    itemEl = publishEl.getChild("item")
                    should.exist itemEl
                    itemEl.attrs.should.have.property "id", "test-A-3"
            ], done

    describe "to a local channel", ->
        it.skip "must be possible for its owner", (done) ->
            done()

        it.skip "must be possible for a publisher", (done) ->
            done()

        it.skip "must not be possible for a member", (done) ->
            done()

        it.skip "must not be possible for an outcast", (done) ->
            done()

        it.skip "must be notified to subscribers", (done) ->
            done()

    describe "to a remote channel", ->
        it.skip "must be submitted to the authoritative server", (done) ->

        it.skip "must be replicated locally", (done) ->

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
        it.skip "must be submitted to the authoritative server", (done) ->

        it.skip "must be replicated locally", (done) ->
