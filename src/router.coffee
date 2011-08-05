errors = require('./errors')
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
                else if results?
                    cb null, results
                else
                    # Was last backend
                    cb (err or new errors.NotFound("Resource not found on any backend"))
        tryBackend()

    notify: (notification) ->
        # TODO: iterate all backends
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
        @model.isListeningToNode node, @remote.getMyJids(), cb

    run: (opts, cb) ->
        console.log 'Router.run': opts, cb: cb
        # TODO: First, look if already subscribed, therefore database is up to date, or if hosted by ourselves
        unless opts.node?
            @runLocally opts, cb
        else
            @isLocallySubscribed opts.node, (err, locallySubscribed) =>
                console.log isLocallySubscribed: { err, locallySubscribed }
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
