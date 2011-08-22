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

    ##
    # If not, we may still find ourselves through disco
    isLocallySubscribed: (node, cb) ->
        @model.nodeExists node, cb

    run: (opts, cb) ->
        console.log 'Router.run': opts, cb: cb

        unless opts.node?
            @runLocally opts, cb
        else if opts.writes
            # Request to mess with data, run remotely
            @remote.run opts, (err, results) =>
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
                    @remote.run opts, cb

    runLocally: (opts, cb) ->
        @operations.run @, opts, cb

    pushData: (opts, cb) ->
        opts.operation = ->
            'push-inbox'
        @operations.run @, opts, cb

    notify: (notification) ->
        @remote.notify notification

    ##
    # Synchronize node from remote
    syncNode: (node, cb) ->
        sync.syncNode @, node, cb

