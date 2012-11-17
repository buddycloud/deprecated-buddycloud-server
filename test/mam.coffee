async = require('async')
should = require('should')
{ NS, TestServer } = require('./test_server')

describe "MAM", ->
    server = new TestServer()

    it "must replay PubSub events to the sender", (done) ->
        @timeout 5000
        mam_begin = new Date().toISOString()

        async.series [(cb) ->
            # We need some data! So publish 2 posts, retract one, add an
            # affiliation and a subscription, and change a channel title. We
            # also add another post in a channel not followed by Picard to check
            # he's not notified of it.
            iqs = [
                server.makePublishIq("riker@enterprise.sf", "buddycloud.example.org",
                    "mam-A-1", "/user/riker@enterprise.sf/posts",
                    content: "Test post A1", id: "mampost-A-1"),
                server.makePublishIq("laforge@enterprise.sf", "buddycloud.example.org",
                    "mam-A-2", "/user/picard@enterprise.sf/posts",
                    content: "Test post A2", id: "mampost-A-2"),
                server.makePublishIq("laforge@enterprise.sf", "buddycloud.example.org",
                    "mam-A-3", "/user/laforge@enterprise.sf/posts",
                    content: "Test post A3", id: "mampost-A-3"),
                server.makePubsubSetIq("laforge@enterprise.sf", "buddycloud.example.org", "mam-A-4")
                    .c("retract", node: "/user/picard@enterprise.sf/posts")
                    .c("item", id: "mampost-A-2"),

                server.makePubsubSetIq("picard@enterprise.sf", "buddycloud.example.org", "mam-A-5")
                    .c("subscribe",
                        jid: "picard@enterprise.sf"
                        node: "/user/mam-user.1@enterprise.sf/posts"),
                server.makePubsubSetIq("riker@enterprise.sf", "buddycloud.example.org", "mam-A-6")
                    .c("subscribe",
                        jid: "riker@enterprise.sf"
                        node: "/user/mam-user.1@enterprise.sf/posts"),
                server.makePubsubSetIq("data@enterprise.sf", "buddycloud.example.org", "mam-A-7")
                    .c("subscribe",
                        jid: "data@enterprise.sf"
                        node: "/user/mam-user.2@enterprise.sf/posts"),

                server.makePubsubOwnerSetIq("mam-user.1@enterprise.sf", "buddycloud.example.org", "mam-A-8")
                    .c("affiliations", node: "/user/mam-user.1@enterprise.sf/posts")
                    .c("affiliation", jid: "riker@enterprise.sf", affiliation: "publisher"),
                server.makePubsubOwnerSetIq("mam-user.2@enterprise.sf", "buddycloud.example.org", "mam-A-9")
                    .c("affiliations", node: "/user/mam-user.2@enterprise.sf/posts")
                    .c("affiliation", jid: "data@enterprise.sf", affiliation: "publisher"),

                server.makePubsubOwnerSetIq("picard@enterprise.sf", "buddycloud.example.org", "mam-A-10")
                    .c("configure", node: "/user/picard@enterprise.sf/status")
                    .cnode(server.makeForm("submit", NS.PUBSUB_NODE_CONFIG, "pubsub#title": "Test title mam-A-10")),

                server.makePubsubOwnerSetIq("data@enterprise.sf", "buddycloud.example.org", "mam-A-11")
                    .c("configure", node: "/user/data@enterprise.sf/status")
                    .cnode(server.makeForm("submit", NS.PUBSUB_NODE_CONFIG, "pubsub#title": "Test title mam-A-11")),

                server.makePubsubOwnerSetIq("riker@enterprise.sf", "buddycloud.example.org", "mam-A-12")
                    .c("configure", node: "/user/riker@enterprise.sf/status")
                    .cnode(server.makeForm("submit", NS.PUBSUB_NODE_CONFIG, "pubsub#title": "Test title mam-A-12"))
            ]
            async.forEachSeries iqs, (iq, cb2) ->
                id = iq.root().attrs.id
                server.doTest iq, "got-iq-#{id}", cb2, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            , cb

        , (cb) ->
            # Now send MAM request
            iq = server.makeIq("get", "picard@enterprise.sf/abc", "buddycloud.example.org", "mam-B-1")
                .c("query", xmlns: NS.MAM, queryid: "mamq-B-1")
                .c("start").t(mam_begin)

            posts = {}
            goodPosts = ["mampost-A-1", "mampost-A-2"]
            badPosts = ["mampost-A-3"]

            subscriptions = []
            goodSubscriptions = [
                ["picard@enterprise.sf", "/user/mam-user.1@enterprise.sf/posts"],
                ["riker@enterprise.sf","/user/mam-user.1@enterprise.sf/posts"]]
            badSubscriptions = [["data@enterprise.sf", "/user/mam-user.2@enterprise.sf/posts"]]

            affiliations = []
            goodAffiliations = [["/user/mam-user.1@enterprise.sf/posts", "riker@enterprise.sf"]]
            badAffiliations = [["/user/mam-user.2@enterprise.sf/posts", "data@enterprise.sf"]]

            configurations = []
            goodConfigurations = ["/user/picard@enterprise.sf/status", "/user/riker@enterprise.sf/status"]
            badConfigurations = ["/user/data@enterprise.sf/status"]

            iqReceived = false

            server.on "got-message-picard@enterprise.sf/abc", (msg) ->
                iqReceived.should.be.false
                msg.attrs.should.have.property("type", "headline")

                resEl = msg.getChild("result", NS.MAM)
                should.exist resEl, "missing element: <result/>"
                resEl.attrs.should.have.property "queryid", "mamq-B-1"

                fwdEl = msg.getChild("forwarded", NS.FORWARD)
                should.exist fwdEl, "missing element: <forwarded/>"

                evt = fwdEl.getChild("message")
                    ?.getChild("event", NS.PUBSUB_EVENT)
                should.exist evt, "missing element: <event/>"
                evt.children.should.not.have.length 0

                for el in evt.children
                    if el.is "items"
                        item = el.getChild "item"
                        should.exist item, "missing element: <item/>"
                        item.attrs.should.have.property "id"
                        id = item.attrs.id
                        if id not of posts
                            posts[id] = 0
                        posts[id] += 1

                    else if el.is "subscription"
                        el.attrs.should.have.property "jid"
                        el.attrs.should.have.property "node"
                        subscriptions.push [el.attrs.jid, el.attrs.node]

                    else if el.is "affiliations"
                        el.attrs.should.have.property "node"
                        for aff in el.getChildren("affiliation")
                            aff.attrs.should.have.property "jid"
                            aff.attrs.should.have.property "affiliation"
                            affiliations.push [el.attrs.node, aff.attrs.jid]

                    else if el.is "configuration"
                        el.attrs.should.have.property "node"
                        configurations.push el.attrs.node

                    else
                        el.should.not.exist

            server.on "got-message-picard@enterprise.sf/def", (msg) ->
                throw new Error("MAM reply for non-sender!")

            server.doTest iq, "got-iq-mam-B-1", cb, (iq) ->
                iqReceived = true
                server.removeAllListeners "got-message-picard@enterprise.sf/abc"
                server.once "got-message-picard@enterprise.sf/abc", (msg) ->
                    throw new Error("message after result iq")
                iq.attrs.should.have.property "type", "result"

                for id in goodPosts
                    posts.should.have.property( id, 1)
                for id in badPosts
                    posts.should.not.have.property(id)

                for aff in goodAffiliations
                    affiliations.should.includeEql aff
                for aff in badAffiliations
                    affiliations.should.not.includeEql aff

                for sub in goodSubscriptions
                    subscriptions.should.includeEql sub
                for sub in badSubscriptions
                    subscriptions.should.not.includeEql sub

                for conf in goodConfigurations
                    configurations.should.include conf
                for conf in badConfigurations
                    configurations.should.not.include conf

        ], (err) ->
            # Wait a second before removing listeners for unwanted messages
            setTimeout ->
                server.removeAllListeners "got-message-picard@enterprise.sf/abc"
                server.removeAllListeners "got-message-picard@enterprise.sf/def"
                done err
            , 1000


    it "must fail if a date is invalid", (done) ->
        good_dates = [
            "1969-07-21T02:56:15Z",
            "1969-07-20T21:56:15-05:00",
        ]
        bad_dates = [
            "1969-07-21 02:56:15Z",
            "1969-07-21T02:56:15",
            "01:23:45",
            "notadate",
        ]
        n = 0

        testMamDate = (date, cb, check) ->
            n += 1
            iq = server.makeIq("get", "picard@enterprise.sf/abc", "buddycloud.example.org", "mam-C-#{n}")
                    .c("query", xmlns: NS.MAM)
                    .c("start").t(date)
            server.doTest iq, "got-iq-mam-C-#{n}", cb, check

        async.series [(cb) ->
            # Test good dates
            async.forEachSeries good_dates, (date, cb2) ->
                testMamDate date, cb2, (iq) ->
                    iq.attrs.should.have.property "type", "result", date
            , cb

        , (cb) ->
            # Test bad dates
            async.forEachSeries bad_dates, (date, cb2) ->
                testMamDate date, cb2, (iq) ->
                    iq.attrs.should.have.property "type", "error", date
            , cb
        ], done


    it "must fail when there are too many results", (done) ->
        mam_begin = new Date(Date.now() - 60000).toISOString()

        # Publish 2 posts, then MAM with a RSM max
        async.series [(cb) ->
            iqs = [
                server.makePublishIq("picard@enterprise.sf", "buddycloud.example.org",
                    "mam-D-1", "/user/picard@enterprise.sf/posts",
                    content: "Test post D1", id: "mampost-D-1"),
                server.makePublishIq("picard@enterprise.sf", "buddycloud.example.org",
                    "mam-D-2", "/user/picard@enterprise.sf/posts",
                    content: "Test post D2", id: "mampost-D-2"),
            ]
            async.forEachSeries iqs, (iq, cb2) ->
                id = iq.root().attrs.id
                server.doTest iq, "got-iq-#{id}", cb2, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            , cb

        , (cb) ->
            iq = server.makeIq("get", "picard@enterprise.sf/abc", "buddycloud.example.org", "mam-D-3")
                    .c("query", xmlns: NS.MAM)
                    .c("start").t(mam_begin).up()
                    .c("set", xmlns: NS.RSM)
                    .c("max").t("1000")

            server.doTest iq, "got-iq-mam-D-3", cb, (iq) ->
                iq.attrs.should.have.property "type", "result"

        , (cb) ->
            iq = server.makeIq("get", "picard@enterprise.sf/abc", "buddycloud.example.org", "mam-D-4")
                    .c("query", xmlns: NS.MAM)
                    .c("start").t(mam_begin).up()
                    .c("set", xmlns: NS.RSM)
                    .c("max").t("1")

            server.doTest iq, "got-iq-mam-D-4", cb, (iq) ->
                iq.attrs.should.have.property "type", "error"
                errEl = iq.getChild "error"
                should.exist errEl, "missing element: <error/>"
                errEl.attrs.should.have.property "type", "modify"
                should.exist errEl.getChild("policy-violation", "urn:ietf:params:xml:ns:xmpp-stanzas")
        ], done
