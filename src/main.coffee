operations = require('./operations')
{makeRequest} = require('./xmpp/pubsub_server')

process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1

process.chdir __dirname

config = require(process.argv[2])

# XMPP Connection, w/ presence tracking
xmppConn = new (require('./xmpp/connection').Connection)(config.xmpp)

# Handle XEP-0060 Publish-Subscribe and related requests:
xmppConn.iqHandler = (stanza) ->
    request = makeRequest stanza
    # TODO: move to router for inbox functionality
    operations.run request

# Resolves user backends by domain
#router = (require('./router').Router)()
# Database storage for local users & cache:

# Other XMPP-federated systems:
#router.addFrontend new (require('./xmpp/pubsub_client').Client)(xmppConn)
