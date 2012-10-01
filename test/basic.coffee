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
