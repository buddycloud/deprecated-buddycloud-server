errors = require('./errors')

CACHE_TIMEOUT = 60 * 1000

class RemoteRouter
    constructor: () ->
        @backends = []
        # cache :: { userId: { queue: [Function], result: ... } }
        @cache = {}

    addBackend: (backend) ->
        @backends.push backend

    resolve: (userId, cb) ->
        backendIdx = 0
        go = () =>
            backend = @backends[backendIdx]
            unless backend
                return cb new errors.NotFound("Cannot resolve user")
            backend.resolve userId, (error, result) ->
                if error
                    backendIdx++
                    go()
                else
                    cb null, result
        go()

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

    resolve: (userId, cb) ->
        # First, look if already subscribed, therefore database is up to date:
        @local.resolve userId, (error, node) ->
            if node
                cb null, node
            else if !error || error.constructor is errors.NotFound
                # Otherwise, fan out to remote service
                @remote.resolve userId, cb
                # TODO: catch if remote backend found ourselves
            else
                cb error

    run: (request) ->
        @operations.run request
