async = require('async')
should = require('should')
moment = require('moment')
{ NS, TestServer } = require('./test_server')

describe "MAM", ->
    server = new TestServer()

# {{{ Test IQs
    # We need some data! So publish 2 posts, retract one, add an affiliation and
    # a subscription, and change a channel title. We also add another post in a
    # channel not followed by Picard to check he's not notified of it.
    testIQs = [
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
# }}}
# {{{ Test function
    testMAM = (sender, isPusher, mamId, since, cb) ->
        iqSender = sender + if isPusher then "" else "/abc"

        iq = server.makeIq("get", iqSender, "buddycloud.example.org", "mam-#{mamId}")
            .c("query", xmlns: NS.MAM, queryid: "mamq-#{mamId}")
            .c("start").t(since)

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

        if isPusher
            goodPosts = goodPosts.concat(badPosts)
            badPosts = []
            goodSubscriptions = goodSubscriptions.concat(badSubscriptions)
            badSubscriptions = []
            goodAffiliations = goodAffiliations.concat(badAffiliations)
            badAffiliations = []
            goodConfigurations = goodConfigurations.concat(badConfigurations)
            badConfigurations = []

        iqReceived = false

        server.on "got-message-#{iqSender}", (msg) ->
            iqReceived.should.be.false
            msg.attrs.should.have.property "type", "headline"

            resEl = msg.getChild "result", NS.MAM
            should.exist resEl, "missing element: <result/>"
            resEl.attrs.should.have.property "queryid", "mamq-#{mamId}"

            fwdEl = msg.getChild "forwarded", NS.FORWARD
            should.exist fwdEl, "missing element: <forwarded/>"

            msgEl = fwdEl.getChild "message"
            should.exist msgEl, "missing element: <message/>"
            msg.children.should.not.have.length 0

            evt = msgEl.getChild "event", NS.PUBSUB_EVENT
            if evt?
                for el in evt.children
                    if el.is "items"
                        children = el.getChildren "item"
                        children.length.should.be.above 0
                        for item in children
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

            xEl = msgEl.getChild "x", NS.DATA
            if xEl?
                xEl.attrs.should.have.property "type", "form"
                # TODO: test pending subscriptions

        unless isPusher?
            server.on "got-message-#{sender}/def", (msg) ->
                throw new Error("MAM reply for non-sender!")

        server.doTest iq, "got-iq-mam-#{mamId}", cb, (iq) ->
            iqReceived = true
            server.removeAllListeners "got-message-#{iqSender}"
            server.once "got-message-#{iqSender}", (msg) ->
                throw new Error("message after result iq")
            iq.attrs.should.have.property "type", "result"

            for id in goodPosts
                posts.should.have.property(id, 1)
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
# }}}

    it "must replay PubSub events to the sender", (done) ->
        @timeout 10000

        async.series [(cb) ->
            # Make sure that we don't catch an older message by accident
            setTimeout cb, 2000

        , (cb) =>
            @mam_begin = moment.utc().format()
            async.forEachSeries testIQs, (iq, cb2) ->
                id = iq.root().attrs.id
                server.doTest iq, "got-iq-#{id}", cb2, (iq) ->
                    iq.attrs.should.have.property "type", "result"
            , cb

        , (cb) =>
            # Test MAM request for a normal user
            testMAM "picard@enterprise.sf", false, "B-1", @mam_begin, cb

        , (cb) =>
            # Test MAM for the pusher component
            testMAM "pusher.example.org", true, "B-2", @mam_begin, cb

        ], (err) ->
            # Wait a second before removing listeners for unwanted messages
            setTimeout ->
                server.removeAllListeners "got-message-picard@enterprise.sf/abc"
                server.removeAllListeners "got-message-picard@enterprise.sf/def"
                server.removeAllListeners "got-message-pusher.example.org"
                done err
            , 1000


    it "must fail if a date is invalid", (done) ->
        good_dates = [
            "1969-07-21T02:56:15Z",
            "1969-07-20T21:56:15-05:00",
        ]
        bad_dates = [
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
        mam_begin = moment().subtract('minutes', 1).utc().format()

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
