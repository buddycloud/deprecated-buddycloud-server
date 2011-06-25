class exports.LocalOperations
    constructor: (backendConfig) ->
        @backend = require('./backend_postgres')
        @backend.start backendConfig

    resolve: (userId, cb) ->
        node = new LocalNode(@backend, userId)
        cb null, node

class LocalContext
    constructor: (backend, userId) ->
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

AFFILIATION_SUBSETS =
  owner: [ "moderator", "publisher", "member", "none" ]
  moderator: [ "publisher", "member", "none" ]
  publisher: [ "member", "none" ]
  member: [ "none" ]

isAffiliationSubset = (subset, affiliation) ->
  subset == affiliation or
            (AFFILIATION_SUBSETS.hasOwnProperty(affiliation) and
             AFFILIATION_SUBSETS[affiliation].indexOf(subset) >= 0)


class OperationContext
    constructor: (opts) ->
        @actor = opts.actor

    checkAffiliation: (cb) ->
        async.parallel [(cb) ->
            t.getConfig req.node, cb
        , (cb) ->
            t.getAffiliation req.node, req.from, cb
        , (cb) ->
            t.getSubscription req.node, req.from, cb
        ], (error, results) ->
            if results
                [config, affiliation, subscription] = results
                if affiliation is "none" and (!config.accessModel? or config.accessModel is "open")
                    affiliation = "member"
                if affiliation is "member" and config.publishModel is "publishers" and subscription is "subscribed"
                    affiliation = "publisher"
        if isAffiliationSubset(@requiredAffiliation, affiliation)
            cb()
        else
            cb new errors.Forbidden(requiredAffiliation + " affiliation required")

    run: (steps, cb) ->
        async.series steps, cb

operation = (steps...) ->
    return (opts, cb) ->
        ctx = new OperationContext(opts)
        ctx.run steps, cb