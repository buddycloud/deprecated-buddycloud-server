errors = require('./errors')

CACHE_TIMEOUT = 60 * 1000

class RemoteRouter
    constructor: () ->
        @backends = []

    addBackend: (backend) ->
        @backends.push backend

    run: (opts, cb) ->
        backends = new Array(@backends...)
        run = ->
            backend = backends.shift()
            backend.run opts, (err, results) ->
                if err && backends.length >= 1
                    # Retry with next backend
                    run()
                else
                    # Was last backend
                    cb err, results

    notify: (notification) ->
        # TODO: iterate all backends
        for backend in backends
            backend.notify notification

##
# Decides whether operations can be served from the local DB by an
# Operation, or to go remote
class Router
    constructor: (@model) ->
        @remote = new RemoteRouter()

        @operations = require('./local/operations')
        @operations.setModel model

    addBackend: (backend) ->
        @remote.addBackend backend

    isLocallySubscribed: (node, cb) ->
        # TODO: get Transaction
        @model.isListeningToNode opts.node, localJids, (err, listening) =>

    run: (opts) ->
        # TODO: First, look if already subscribed, therefore database is up to date:
        if not opts.node?
            @operations.run opts
        else
            @isLocallySubscribed opts.node, (err, locallySubscribed) =>
                if locallySubscribed
                    @operations.run opts
                else
                    @remote.run opts, ->
    notify: (notification) ->
        @remote.notify notification
