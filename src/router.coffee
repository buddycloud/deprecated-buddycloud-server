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
            console.log tryBackend: backend
            backend.run @router, opts, (err, results) ->
                if err && backends.length >= 1
                    # Retry with next backend
                    tryBackend()
                else
                    # Was last backend
                    cb err, results
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

    run: (opts) ->
        console.log 'Router.run': opts
        # TODO: First, look if already subscribed, therefore database is up to date, or if hosted by ourselves
        unless opts.node?
            @runLocally
        else
            @isLocallySubscribed opts.node, (err, locallySubscribed) =>
                console.log isLocallySubscribed: { err, locallySubscribed }
                if locallySubscribed
                    @runLocally opts
                else
                    # run remotely
                    @remote.run opts, ->

    runLocally: (opts) ->
        @operations.run @, opts

    notify: (notification) ->
        @remote.notify notification
