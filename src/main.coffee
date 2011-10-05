path = require('path')
async = require('async')
config = require('jsconfig')
defaultConfigPath = path.join(__dirname,"..","..","config")
config.defaults(defaultConfigPath)

config.set 'env',
    HOST: 'xmpp.host'
    PORT: ['xmpp.port', parseInt]

config.cli
    host: ['xmpp.host', ['b', "xmpp server listen address", 'host']]
    port: ['xmpp.port', ['p', "xmpp server listen port",  'number']]
    config: ['c', "load config file", 'path', defaultConfigPath]
    debug: [off, "enable debug mode"]
    nobuild: [off, "[INTERNAL] disable build"]

config.load (args, opts) ->
    config.merge(require(opts.config))

    if opts.debug
        process.on 'uncaughtException', (err) ->
            console.error "uncaughtException: #{err.stack || err.message || err.toString()}"



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
        console.log request: request, operation: request.operation
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
        opts.operation = 'push-inbox'
        router.run opts, ->

    pubsubBackend.on 'syncNeeded', (server) ->
        router.syncServer server, ->

    pubsubBackend.on 'authorizationPrompt', (opts) ->
        # verify node authority
        pubsubBackend.authorizeFor opts.sender, opts.nodeOwner, (err, valid) ->
            if valid
                # Just relay
                opts.type = 'authorizationPrompt'
                router.notify opts

    pubsubBackend.on 'authorizationConfirm', (opts) ->
        opts.operation = 'confirm-subscriber-authorization'
        router.run opts, ->

    # Clean-up for anonymous users
    xmppConn.on 'userOffline', (user) ->
        router.onUserOffline user

    xmppConn.on 'online', ->
        model.forListeners (listener) ->
            xmppConn.probePresence(listener)

        router.setupSync Math.ceil((config.modelConfig.poolSize or 2) / 2)
