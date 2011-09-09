errors = require('./errors')
sync = require('./sync')
async = require('async')

CACHE_TIMEOUT = 60 * 1000

##
# Routes to multiple backends
class RemoteRouter
    constructor: (@router) ->
        @backends = []

    addBackend: (backend) ->
        @backends.push backend

    getMyJids: ->
        jids = []
        @backends.map (backend) ->
            if backend.getMyJids?
                jids.push(backend.getMyJids()...)
        jids

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

    authorizeFor: (sender, actor, cb) ->
        backends = new Array(@backends...)
        tryBackend = =>
            backend = backends.shift()
            backend.authorizeFor sender, actor, (err, valid) ->
                if err && !valid
                    # Retry with next backend
                    tryBackend()
                else
                    # Was valid or last backend
                    cb err, valid
        tryBackend()

##
# Decides whether operations can be served from the local DB by an
# Operation, or to go remote
class exports.Router
    constructor: (@model) ->
        @remote = new RemoteRouter(@)

        @operations = require('./local/operations')
        @operations.setModel model

    addBackend: (backend) ->
        @remote.addBackend backend

    authorizeFor: (args...) ->
        @remote.authorizeFor(args...)

    ##
    # If not, we may still find ourselves through disco
    isLocallySubscribed: (node, cb) ->
        @model.nodeExists node, cb

    runLocally: (opts, cb) ->
        @operations.run @, opts, cb

    runRemotely: (opts, cb) ->
        @remote.run opts, cb

    run: (opts, cb) ->
        console.log 'Router.run': opts, cb: cb

        unless opts.node?
            @runLocally opts, cb
        else if opts.dontCache
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
