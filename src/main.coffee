process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1
config = require("#{process.cwd()}/#{process.argv[2]}")

errors = require('./errors')

backend = require('./local/backend_postgres')
backend.start config.modelConfig

operations = require('./local/operations')
operations.setBackend backend

{makeRequest} = require('./xmpp/pubsub_server')


# XMPP Connection, w/ presence tracking
xmppConn = new (require('./xmpp/connection').Connection)(config.xmpp)
pubsubBackend = new (require('./xmpp/backend_pubsub').PubsubBackend)(xmppConn)

# Handle XEP-0060 Publish-Subscribe and related requests:
xmppConn.iqHandler = (stanza) ->
    request = makeRequest stanza
    console.log request: request, operation: request.operation()
    if request.sender isnt request.actor
        # Validate if sender is authorized to act on behalf of the
        # actor (TODO!)
        pubsubBackend.authorizeFor request.sender, request.actor, (err, valid) ->
            if err
                stanza.replyError err
            else unless valid
                stanza.reply new errors.BadRequest('Requesting service not authorized for actor')
            else
                operations.run request
    else
        # TODO: move to router for inbox functionality
        operations.run request

# Resolves user backends by domain
#router = (require('./router').Router)()
# Database storage for local users & cache:

# Other XMPP-federated systems:
#router.addFrontend new (require('./xmpp/pubsub_client').Client)(xmppConn)
