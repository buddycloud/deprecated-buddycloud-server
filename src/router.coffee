logger = require('./logger').makeLogger 'router'
errors = require('./errors')
sync = require('./sync')
async = require('async')

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
        # Proxy to @remote.detectAnonymousUser, but uses above cache
        @detectAnonymousUser = (user, cb) =>
            if @anonymousUsers.hasOwnProperty(user) and @anonymousUsers[user]
                cb null, true
            else
                @remote.detectAnonymousUser user, cb

    ##
    # If not, we may still find ourselves through disco
    isLocallySubscribed: (node, cb) ->
        @model.nodeExists node, cb

    runLocally: (opts, cb) ->
        @operations.run @, opts, cb

    runRemotely: (opts, cb) ->
        @remote.run opts, cb

    run: (opts, cb) ->
        logger.debug 'Router.run': opts, cb: cb

        @runCheckAnonymous opts, (err) =>
            if err
                return cb err

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
        unless opts.writes
            # No writing request, no need to check...
            cb()
        else
            @detectAnonymousUser opts.actor, (err, isAnonymous) =>
                if err
                    # Can't make sure? Fall back to stupid heuristics:
                    isAnonymous = (opts.actor.indexOf('@anon') >= 0)

                # Disallow any writing requests except
                # (un)subscribing, for which we do explicit clean-up
                # upon unavailable presence.
                if isAnonymous and opts.writes
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
                    cb()


    pushData: (opts, cb) ->
        opts.operation = 'push-inbox'
        @operations.run @, opts, cb

    notify: (notification) ->
        @remote.notify notification

    ##
    # Synchronize node from remote
    setupSync: (jobs) ->
        sync.setup @, @model, jobs

    syncNode: (node, cb) ->
        sync.syncNode @, @model, node, cb

    syncServer: (server, cb) ->
        sync.syncServer @, @model, server, cb

    # No need to @detectAnonymousUser() again:
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
