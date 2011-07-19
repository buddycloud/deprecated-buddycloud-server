process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1
config = require("#{process.cwd()}/#{process.argv[2]}")

backend = require('./local/backend_postgres')
backend.start config.modelConfig

operations = require('./local/operations')
operations.setBackend backend

{makeRequest} = require('./xmpp/pubsub_server')


# XMPP Connection, w/ presence tracking
xmppConn = new (require('./xmpp/connection').Connection)(config.xmpp)

# Handle XEP-0060 Publish-Subscribe and related requests:
xmppConn.iqHandler = (stanza) ->
    request = makeRequest stanza
    console.log request: request, operation: request.operation()
    # TODO: move to router for inbox functionality
    operations.run request

# Resolves user backends by domain
#router = (require('./router').Router)()
# Database storage for local users & cache:

# Other XMPP-federated systems:
#router.addFrontend new (require('./xmpp/pubsub_client').Client)(xmppConn)
