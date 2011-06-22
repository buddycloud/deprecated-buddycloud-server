errors = require('./errors')

CACHE_TIMEOUT = 60 * 1000

class RemoteRouter
    constructor:
        @frontends = []
        # userId: { queue: [Function], result: ... }
        @cache = {}

    addFrontend: (frontend) ->
        @frontends.push frontend

    resolve: (userId, cb) ->
        if userId of @cache
            if @cache[userId].result
                cb null, @cache[userId].result
            else if @cache[userId].error
                cb @cache[userId].error
            else
                # Already resolving:
                @cache[userId].queue.push cb
        else
            # New:
            @cache[userId] =
                queue: cb
            do_resolve_ userId, (error, result) =>
                if error
                    for cb in @cache[userId].queue
                        cb error
                    @cache[userId] =
                        error: error
                else
                    for cb in @cache[userId].queue
                        cb null, result
                    @cache[userId] =
                        result: result
                setTimeout () =>
                    delete @cache[userId]
                    # TODO: shorter for the error case
                , CACHE_TIMEOUT

    do_resolve_: (userId, cb) ->
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

class Router
    constructor: () ->
        @remote = new RemoteRouter()

    addFrontend: (frontend) ->
        @remote.addFrontend frontend

    operation: () ->
        # First, look if already subscribed, therefore database is up to date:

        # Otherwise, fan out to remote service
        @remote.resolve
