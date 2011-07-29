process.on 'uncaughtException', (err) ->
    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

if process.argv.length < 3
    console.error "Usage: #{process.argv[0]} #{process.argv[1]} <config.js>"
    process.exit 1
config = require("#{process.cwd()}/#{process.argv[2]}")

errors = require('./errors')

model = require('./local/model_postgres')
model.start config.modelConfig

router = new (require('./router').Router)(model)

# XMPP Connection, w/ presence tracking
xmppConn = new (require('./xmpp/connection').Connection)(config.xmpp)
pubsubServer = new (require('./xmpp/pubsub_server').PubsubServer)(xmppConn)
pubsubBackend = new (require('./xmpp/backend_pubsub').PubsubBackend)(xmppConn)

# Handle XEP-0060 Publish-Subscribe and related requests:
pubsubServer.onRequest = (request) ->
    console.log request: request, operation: request.operation()
    if request.sender isnt request.actor
        # Validate if sender is authorized to act on behalf of the
        # actor
        pubsubBackend.authorizeFor request.sender, request.actor, (err, valid) ->
            if err
                stanza.replyError err
            else unless valid
                stanza.reply new errors.BadRequest('Requesting service not authorized for actor')
            else
                # Pass to router
                router.run request
    else
        # Pass to router
        router.run request

# Other XMPP-federated systems:
#router.addFrontend new (require('./xmpp/pubsub_client').Client)(xmppConn)
