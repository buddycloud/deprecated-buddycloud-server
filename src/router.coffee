logger = require('./logger').makeLogger 'router'
{inspect} = require('util')
errors = require('./errors')
sync = require('./sync')
async = require('async')
rsmWalk = require('./rsm_walk')
{RSM} = require('./xmpp/rsm')
{getNodeUser} = require('./util')

CACHE_TIMEOUT = 60 * 1000

##
# Routes to multiple backends
class RemoteRouter
    constructor: (@router) ->
        @backends = []

    addBackend: (backend) =>
        @backends.push backend

    getMyJids: ->
        jids = []
        @backends.map (backend) ->
            if backend.getMyJids?
                jids.push(backend.getMyJids()...)
        jids

    isUserOnline: (user) =>
        @backends.some (backend) ->
            backend.isUserOnline user

    run: (opts, cb) ->
        backends = new Array(@backends...)
        tryBackend = =>
            backend = backends.shift()
            backend.run @router, opts, (err, results) ->
                if err && backends.length > 0
                    # Retry with next backend
                    tryBackend()
                else
                    # Was last backend
                    cb err, results
        tryBackend()

    notify: (notification) ->
        for backend in @backends
            backend.notify notification

    authorizeFor: (sender, actor, cb) =>
        backends = new Array(@backends...)
        tryBackend = =>
            backend = backends.shift()
            backend.authorizeFor sender, actor, (err, valid) ->
                if (err or !valid) and backends.length > 0
                    # Retry with next backend
                    tryBackend()
                else
                    # Was valid or last backend
                    cb err, valid
        tryBackend()

    detectAnonymousUser: (user, cb) =>
        backends = new Array(@backends...)
        tryBackend = =>
            backend = backends.shift()
            backend.detectAnonymousUser user, (err, isAnonymous) ->
                if err and backends.length > 0
                    # Retry with next backend
                    tryBackend()
                else
                    # Was valid or last backend
                    cb err, isAnonymous
        tryBackend()

##
# Decides whether operations can be served from the local DB by an
# Operation, or to go remote
class exports.Router
    constructor: (@model) ->
        @remote = new RemoteRouter(@)

        @operations = require('./local/operations')
        @operations.setModel model

        @addBackend = @remote.addBackend
        @isUserOnline = @remote.isUserOnline
        @authorizeFor = @remote.authorizeFor

        # Keep them for clean-up upon unavailable presence
        @anonymousUsers = {}

        ##
        # Block any requests on a node that has sync pending. The
        # alternative was: push notifications after sync, but that may
        # be unnecessary in many cases.
        @perNodeQueue = {}

    detectUserType: (user, cb) ->
        if user.indexOf("@") >= 0
            # '@' in JID means it's a user or anonymous
            if @anonymousUsers.hasOwnProperty(user) and @anonymousUsers[user]
                cb null, true
            else
                @remote.detectAnonymousUser user, (err, isAnonymous) =>
                    if err and user.indexOf('@anon') >= 0
                        # Can't make sure? Fall back to stupid heuristics:
                        cb null, 'anonymous'
                    else if isAnonymous
                        cb null, 'anonymous'
                    else
                        cb null, 'user'
        else
            cb null, 'server'

    ##
    # If not, we may still find ourselves through disco
    isLocallySubscribed: (node, cb) ->
        @model.nodeExists node, cb

    runLocally: (opts, cb) ->
        if opts.node and @perNodeQueue.hasOwnProperty(opts.node)
            @perNodeQueue[opts.node].push =>
                @runLocally opts, cb
        else
            @operations.run @, opts, cb

    runRemotely: (opts, cb) ->
        @remote.run opts, cb

    run: (opts, cb) ->
        logger.trace "Router.run %s", inspect(opts)
        @runCheckAnonymous opts, (err) =>
            if err
                return cb err

            logger.info "Router.run #{opts.actor}(#{opts.actorType})/#{opts.sender}: #{opts.operation} #{opts.node}"

            unless opts.node?
                @runLocally opts, cb
            else if opts.writes
                # Request to mess with data, run remotely
                @runRemotely opts, (err, results) =>
                    if err and err.constructor is errors.SeeLocal
                        # Remote discovered ourselves
                        @runLocally opts, cb
                    else
                        # result/error from remote
                        cb err, results
            else
                @isLocallySubscribed opts.node, (err, locallySubscribed) =>
                    if locallySubscribed
                        @runLocally opts, cb
                    else
                        # run remotely
                        @runRemotely opts, (err, results) ->
                            if err?.constructor is errors.SeeLocal
                                # Is not locally present but discovery
                                # returned ourselves.
                                cb new errors.NotFound("Node does not exist here")
                            else
                                cb err, results

    runCheckAnonymous: (opts, cb) ->
        # May have been set by pubsub_server or previous recursion
        # (see tail of this method)
        if opts.actorType
            unless opts.writes
                # No writing request, no need to check further...
                cb()
            else
                # Disallow any writing requests except
                # (un)subscribing, for which we do explicit clean-up
                # upon unavailable presence.
                if opts.actorType is 'anonymous'
                    if opts.operation is 'subscribe-node' or
                       opts.operation is 'unsubscribe-node'
                        if @isUserOnline opts.actor
                            # Allow but track
                            @anonymousUsers[opts.actor] = true
                            cb()
                        else
                            cb new errors.Forbidden("Send presence to be able to temporarily subscribe.")
                    else
                        # Disallow
                        cb new errors.NotAllowed("You are anonymous. You are legion.")
                else
                    # Not anonymous, allow everything
                    cb()
        else
            @detectUserType opts.actor, (err, type) =>
                opts.actorType = type or 'user'
                # Finally recurse:
                @runCheckAnonymous opts, cb

    pushData: (opts, cb) ->
        opts.operation = 'push-inbox'
        @runLocally opts, cb

    notify: (notification) ->
        @remote.notify notification

    ##
    #
    # Also goes to the backend to sync all nodes
    setupSync: (jobs) ->
        sync.setup jobs

        @model.getAllNodes (err, nodes) =>
            if err
                logger.error "getAllNodes %s", err.stack or err
                return

            for node in nodes
                @syncNode node, (err) ->
                    if err
                        logger.error err
            # TODO: once batchified, syncQueue.drain = ...

    ##
    # Synchronize node from remote
    syncNode: (node, cb) ->
        unless @perNodeQueue.hasOwnProperty(node)
            @perNodeQueue[node] = []
        sync.syncNode @, @model, node, (err) =>
            blocked = @perNodeQueue[node] or []
            delete @perNodeQueue[node]
            blocked.forEach (cb1) ->
                cb1()

            cb(err)

    ##
    # Batchified by walking RSM: the next result set page will be
    # requested after all nodes have been processed.
    syncServer: (server, cb) ->
        opts =
            operation: 'retrieve-user-subscriptions'
            jid: server
        opts.rsm = new RSM()
        rsmWalk (nextOffset, cb2) =>
            opts.rsm.after = nextOffset
            @runRemotely opts, (err, results) =>
                if err
                    return cb2 err

                async.forEach results, (subscription, cb3) =>
                    unless subscription.node
                        # Weird, skip;
                        return cb3()

                    user = getNodeUser(subscription.node)
                    unless user
                        # Weird, skip;
                        return cb3()

                    @authorizeFor server, user, (err, valid) =>
                        if err or !valid
                            logger.warn((err and err.stack) or err or
                                "Cannot sync #{subscription.node} from unauthorized server #{server}"
                            )
                            cb3()
                        else
                            @syncNode subscription.node, (err) ->
                                # Ignore err, a single node may fail
                                cb3()
                , (err) ->
                    cb2 err, results?.rsm?.last
        , cb

    # No need to detectAnonymousUser() again:
    # * Disco info may not be available anymore
    # * If missing from anonymousUsers no clean-up is needed
    onUserOffline: (user) ->
        if @anonymousUsers.hasOwnProperty(user) and @anonymousUsers[user]
            delete @anonymousUsers[user]
            req =
                operation: 'remove-user'
                actor: user
                sender: user
            runLocally req, ->
