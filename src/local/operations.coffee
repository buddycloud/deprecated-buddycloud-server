class exports.LocalOperations
    constructor: (backendConfig) ->
        @backend = require('./backend_postgres')
        @backend.start backendConfig

    resolve: (userId, cb) ->
        node = new LocalNode(@backend, userId)
        cb null, node

class LocalContext
    constructor: (backend) ->
        @backend = backend

    register: operation () ->
        async.parallel [
            "channel", "mood", "subscriptions",
            "geo/current", "geo/future", "geo/previous" ].map((name) ->
                node = "/user/" + user + "/" + name
                return (cb) ->
                    async.series [(cb) ->
                        @t.createNode node, cb
                    , (cb) ->
                        @t.setConfig node, defaultConfig(@actor), cb
                    , (cb) ->
                        @t.setAffiliation node, @actor, "owner", cb
                    , (cb) ->
                        @t.setSubscription node, @actor, "subscribed", cb
                    , cb
            )
        ], @cb


defaultConfig = (actor) ->
    owner = actor
    title: owner + "'s node"
    description: "Where " + owner + " publishes things"
    type: "http://www.w3.org/2005/Atom"
    accessModel: "open"
    publishModel: "subscribers"
    creationDate: new Date().toISOString()


class OperationContext
    constructor: (opts) ->
        @actor = opts.actor

operation = (steps...) ->
    return (opts, cb) ->