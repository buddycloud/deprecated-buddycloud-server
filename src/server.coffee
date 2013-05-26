# 3rd-party libs
fs         = require('fs')
path       = require('path')
async      = require('async')
{inspect}  = require('util')
moment     = require('moment')
Connection = require('./xmpp/connection')
xmpp       = require('node-xmpp')
NS         = require('./xmpp/ns')
version    = require('./version')

exports.getConfig = (cb) ->
    # Config
    config = require('jsconfig')
    defaultConfigFile = path.join(__dirname,"..","config.js")
    if fs.existsSync(defaultConfigFile)
        config.defaults defaultConfigFile

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

    config.load (args, opts) ->
        if opts.version
            console.log version
            process.exit 0

        if opts.config?.length
            unless opts.config[0] is '/'
                opts.config = path.join(process.cwd(), opts.config)
            # Always reload config for -c argument
            config.merge(opts.config)
        else if fs.existsSync("/etc/buddycloud-server/config.js")
            config.merge("/etc/buddycloud-server/config.js")

        # Kludge:
        if opts.stdout
            config.logging.stdout = true

        cb config

exports.startServer = (config) ->
    process.title = "buddycloud-server #{version}"

    # Date format
    moment.defaultFormat = "YYYY-MM-DDTHH:mm:ss.SSSZ"

    # Logger
    logger_ = require('./logger')
    logger_.setConfig config.logging
    logger = logger_.makeLogger 'main'

    if config.debug
        process.on 'uncaughtException', (err) ->
            logger.error "uncaughtException: #{err.stack || err.message || err.toString()}"

    errors = require('./errors')

    model = require('./local/model_postgres')
    model.start config.modelConfig
    model.checkSchemaVersion()

    router = new (require('./router').Router)(model, config.checkCreateNode, config.autosubscribeNewUsers, config.pusherJid)

    # XMPP Connection, w/ presence tracking
    xmppConn = new (Connection.Connection)(config.xmpp)
    pubsubServer = new (require('./xmpp/pubsub_server').PubsubServer)(xmppConn)
    pubsubBackend = new (require('./xmpp/backend_pubsub').PubsubBackend)(xmppConn)
    router.addBackend pubsubBackend

    # Handle XEP-0060 Publish-Subscribe and related requests:
    pubsubServer.on 'request', (request) ->
        logger.trace "request: #{inspect request}"
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
        logger.trace "notificationPush: #{inspect(opts)}"
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

    # Clean-up for anonymous users and temporary subscriptions
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

        # wait for a fully initialised server before starting tasks
        startup = ->
            async.series [(cb) ->
                model.cleanupTemporaryData (err) ->
                    if err
                        logger.error "cleanup temporary data: #{err.stack or err}"
                    cb err
            , (cb) ->
                unless config.testMode
                    router.setupSync Math.ceil((config.modelConfig.poolSize or 2) / 2)
                cb null
            ], (err) ->
                if err
                    logger.error err
        setTimeout startup, 5000

    if !config.advertiseComponents?
        config.advertiseComponents = []
    for index of config.advertiseComponents
        componentConfig = {}
        for key, value of config.xmpp
            componentConfig[key] = value
        componentConfig.jid = config.advertiseComponents[index]
        componentConfig.reconnect = true
        connection = new xmpp.Component(componentConfig)
        connection.on "error", (e) ->
            logger.error e
        connection.on "stanza", (stanza) =>
            # Just debug output:
            logger.trace "<< Extra connection request: #{stanza.toString()}"
            from = stanza.attrs.from

            if stanza.name is 'iq' and stanza.attrs.type is 'get'
                # IQ requests
                if !stanza.children?
                    stanza.children = []
                for i, child of stanza.children
                    if child.name is 'query'
                        query = child
                if !query?
                    return
                switch query.attrs.xmlns
                    when NS.DISCO_ITEMS
                        reply = new xmpp.Element("iq",
                            from: stanza.attrs.to
                            to: stanza.attrs.from
                            id: stanza.attrs.id or ""
                            type: "result"
                            xmlns: Connection.NS_STREAM).
                            c('query', xmlns: NS.DISCO_ITEMS).
                            c('item', jid: config.xmpp.jid, name: 'buddycloud-server')
                    when NS.DISCO_INFO
                        reply = new xmpp.Element("iq",
                            from: stanza.attrs.to
                            to: stanza.attrs.from
                            id: stanza.attrs.id or ""
                            type: "result"
                            xmlns: Connection.NS_STREAM).
                            c('query', xmlns: NS.DISCO_INFO).
                            c('feature', var: NS.DISCO_INFO).up().
                            c('feature', var: NS.DISCO_ITEMS).up().
                            c('feature', var: NS.REGISTER).up().
                            c('identity', category:'pubsub', type:'service', name:'Buddycloud proxy domain')
                    else
                        return
                logger.trace "<< Extra connection response: #{reply.root().toString()}"
                connection.send reply

    return xmppConn
