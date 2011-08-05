#process.on 'uncaughtException', (err) ->
#    console.error "uncaughtException: #{err.stack || err.message || err.toString()}"

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
router.addBackend pubsubBackend

# Handle XEP-0060 Publish-Subscribe and related requests:
pubsubServer.on 'request', (request) ->
    console.log request: request, operation: request.operation()
    if request.sender isnt request.actor
        # Validate if sender is authorized to act on behalf of the
        # actor
        pubsubBackend.authorizeFor request.sender, request.actor, (err, valid) ->
            if err
                request.callback err
            else unless valid
                request.callback new errors.BadRequest('Requesting service not authorized for actor')
            else
                # Pass to router
                router.run request, (args...) ->
                    request.callback(args...)
    else
        # Pass to router
        router.run request, (args...) ->
            request.callback(args...)

# Handle incoming XEP-0060 Publish-Subscribe notifications
pubsubBackend.on 'notificationPush', (opts) ->
    console.log notificationPush: opts
    # Sender is already authenticated at this point
    opts.operation = ->
        'push-inbox'
    router.run opts, ->
