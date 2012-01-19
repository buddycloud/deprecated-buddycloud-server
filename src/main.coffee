# 3rd-party libs
path = require('path')
async = require('async')
{inspect} = require('util')
# Config
config = require('jsconfig')
# Included
try
    { version } = require('../package.json')
catch e
    { version } = JSON.parse(require('fs').readFileSync(path.join(__dirname,'..','package.json')))

process.title = "buddycloud-server #{version}"

config.set 'ignore unknown', yes
config.set 'env',
    HOST: 'xmpp.host'
    PORT: ['xmpp.port', parseInt]

config.cli
    host: ['xmpp.host', ['b', "xmpp server listen address", 'host']]
    port: ['xmpp.port', ['p', "xmpp server listen port",  'number']]
    config: ['c', "load config file", 'path']
    debug: [off, "enable debug mode"]
    nobuild: [off, "[INTERNAL] disable build"]
    stdout: ['logging.stdout', [off, "Log to stdout"]]
    version: [off, "Display version"]

config.load path.join(__dirname,"..","config.js"), "/etc/buddycloud-server/config.js", (args, opts) ->

    if opts.version
        console.log version
        process.exit 0

    if opts.config
        unless opts.config[0] is '/'
            opts.config = require(path.join(process.cwd(), opts.config))
        # Always reload config for -c argument
        config.merge(opts.config)

    # Kludge:
    if opts.stdout
        config.logging.stdout = true
    # Logger
    logger_ = require('./logger')
    logger_.setConfig config.logging
    logger = logger_.makeLogger 'main'

    if opts.debug
        process.on 'uncaughtException', (err) ->
            logger.error "uncaughtException: #{err.stack || err.message || err.toString()}"


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
        logger.trace "request: %s", inspect(request)
        if request.operation is 'get-version'
            request.callback null,
                name: "buddycloud-server"
                version: version
                os: process.platform
        else if request.sender isnt request.actor
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
        logger.trace "notificationPush: %s", inspect(opts)
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
        logger.info "XMPP connection established"
        process.title = "buddycloud-server #{version}: #{xmppConn.jid}"
        saidHello = no
        model.forListeners (listener) ->
            unless saidHello
                logger.info "server successfully started"
                saidHello = yes
            xmppConn.probePresence(listener)

        router.setupSync Math.ceil((config.modelConfig.poolSize or 2) / 2)
