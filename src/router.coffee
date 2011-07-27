errors = require('./errors')

CACHE_TIMEOUT = 60 * 1000

class RemoteRouter
    constructor: () ->
        @frontends = []
        # cache :: { userId: { queue: [Function], result: ... } }
        @cache = {}

    addFrontend: (frontend) ->
        @frontends.push frontend

    resolve: (userId, cb) ->
        frontendIdx = 0
        go = () =>
            frontend = @frontends[frontendIdx]
            unless frontend
                return cb new errors.NotFound("Cannot resolve user")
            frontend.resolve userId, (error, result) ->
                if error
                    frontendIdx++
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

    addFrontend: (frontend) ->
        @remote.addFrontend frontend

    resolve: (userId, cb) ->
        # First, look if already subscribed, therefore database is up to date:
        @local.resolve userId, (error, node) ->
            if node
                cb null, node
            else if !error || error.constructor is errors.NotFound
                # Otherwise, fan out to remote service
                @remote.resolve userId, cb
                # TODO: catch if remote frontend found ourselves
            else
                cb error

    run: (request) ->
        @operations.run request
