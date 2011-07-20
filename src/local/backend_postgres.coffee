pg = require("pg")
async = require("async")
errors = require("../errors")

# ready DB connections
pool = []
# waiting transaction requests
queue = []

# at start and when connection died
connectDB = (config) ->
    db = new pg.Client(config)
    db.connect()
    # Reconnect in up to 5s
    db.on "error", (err) ->
        console.error "Postgres: " + err.message
        setTimeout ->
            connectDB config
        , Math.ceil(Math.random() * 5000)
        try
            db.end()
        catch e

    # wait until connected & authed
    db.connection.once "readyForQuery", ->
        dbIsAvailable db

dbIsAvailable = (db) ->
    if (cb = queue.shift())
        # request was waiting in queue
        cb db
    else
        # no request, put into pool
        pool.push db

# config: { user, database, host, port, poolSize: 4 }
exports.start = (config) ->
    for i in [0..(config.poolSize or 4)]
        connectDB config

exports.transaction = (cb) ->
    if (db = pool.shift())
        # Got one from pool
        new Transaction(db, cb)
    else
        # Pool was empty, waiting... TODO: limit length, shift first
        queue.push (db) ->
            new Transaction(db, cb)

##
# Wraps the postgres-js transaction with our model operations.
class Transaction
    constructor: (db, cb) ->
        that = this
        @db = db
        db.query "BEGIN", [], (err, res) ->
            cb err, that

    commit: (cb) ->
        @db.query "COMMIT", [], (err, res) =>
            process.nextTick =>
                dbIsAvailable @db

            cb err

    rollback: (cb) ->
        @db.query "ROLLBACK", [], (err, res) =>
            process.nextTick =>
                dbIsAvailable @db

            cb err

    ##
    # Actual data model

    ##
    # Can be dropped in a async.waterfall() sequence to validate presence of a node.
    nodeExists: (node) ->
        db = @db
        (cb) ->
            async.waterfall [(cb2) ->
                db.query "SELECT node FROM nodes WHERE node=$1", [ node ], cb2
            , (res, cb2) ->
                if res.rowCount < 1
                    cb2 new errors.NotFound("Node does not exist")
                else
                    cb2 null
            ], cb

    createNode: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            if res.rowCount > 0
                # Node already exists: ignore
                cb2(null)
            else
                db.query "INSERT INTO nodes (node) VALUES ($1)", [ node ], cb2
        ], cb

    ##
    # cb(err, [{ node: String, title: String }])
    listNodes: (cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", cb2
        , (res, cb2) ->
            nodes = res.rows.map (row) ->
                node: row.node
                title: row.title
            cb2 null, nodes
        ], cb

    listNodesByUser: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM nodes WHERE position('/user/' || $1 IN node) = 1 AND node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", [ user ], cb2
        , (res, cb2) ->
            nodes = res.rows.map (row) ->
                node: row.node
                title: row.title
            cb2 null, nodes
        ], cb

    ##
    # Subscription management
    ##

    getSubscription: (node, user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND user=$2", [ node, user ], cb2
        , (res, cb2) ->
            cb2 null, (res.rows[0] and res.rows[0].subscription) or "none"
        ], cb

    setSubscription: (node, user, subscription, cb) ->
        db = @db
        toDelete = not subscription or subscription == "none"
        async.waterfall [ @nodeExists(node), (cb2) ->
            db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            isSet = res?.rows?[0]
            console.log "setSubscription #{node} #{user} isSet=#{isSet} toDelete=#{toDelete}"
            if isSet and not toDelete
                db.query "UPDATE subscriptions SET subscription=$1 WHERE node=$2 AND \"user\"=$3", [ subscription, node, user ], cb2
            else if not isSet and not toDelete
                db.query "INSERT INTO subscriptions (node, \"user\", subscription) VALUES ($1, $2, $3)", [ node, user, subscription ], cb2
            else if isSet and toDelete
                db.query "DELETE FROM subscriptions WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
            else if not isSet and toDelete
                cb2 null
            else
                cb2 new Error('Invalid subscription transition')
        ], cb

    getSubscribers: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", subscription FROM subscriptions WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            subscribers = []
            res.rows.forEach (row) ->
                subscribers.push
                    user: row.user
                    subscription: row.subscription

            cb2 null, subscribers
        ], cb

    getSubscriptions: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node, subscription FROM subscriptions WHERE \"user\"=$1", [ user ], cb
        , (res, cb2) ->
            subscriptions = []
            res.rows.forEach (row) ->
                subscriptions.push
                    node: row.node
                    subscription: row.subscription

            cb2 null, subscriptions
        ], cb

    getAllSubscribers: (cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT DISTINCT \"user\" FROM subscriptions", cb2
        , (res, cb2) ->
            subscribers = []
            res.rows.forEach (row) ->
                subscribers.push row.user

            cb2 null, subscribers
        ], cb

    getPingNodes: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node FROM affiliations WHERE affiliation = 'owner' AND \"user\" = $1 AND EXISTS (SELECT \"user\" FROM subscriptions WHERE subscription = 'pending' AND node = affiliations.node)", [ user ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.node
            )
        ], cb

    getPending: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT user FROM subscriptions WHERE subscription = 'pending' AND node = $1", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    ##
    # Affiliation management
    ##

    getAffiliation = (node, user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            cb2 null, (res.rows[0] and res.rows[0].affiliation) or "none"
        ], cb

    setAffiliation = (node, user, affiliation, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            toDelete = not affiliation or affiliation == "none"
            if isSet and not toDelete
                db.query "UPDATE affiliations SET affiliation=$1 WHERE node=$2 AND \"user\"=$3", [ affiliation, node, user ], cb2
            else if not isSet and not toDelete
                db.query "INSERT INTO affiliations (node, \"user\", affiliation) VALUES ($1, $2, $3)", [ node, user, affiliation ], cb2
            else if isSet and toDelete
                db.query "DELETE FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], cb2
            else if not isSet and toDelete
                cb2 null
        ], cb

    getAffiliations: (user, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT node, affiliation FROM affiliations WHERE \"user\"=$1", [ user ], cb2
        , (res, cb2) ->
            affiliations = []
            res.rows.forEach (row) ->
                affiliations.push
                    node: row.node
                    affiliation: row.affiliation

            cb2 null, affiliations
        ], cb

    getAffiliated: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\", affiliation FROM affiliations WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            affiliations = []
            res.rows.forEach (row) ->
                affiliations.push
                    user: row.user
                    affiliation: row.affiliation

            cb2 null, affiliations
        ], cb

    getOwners: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT \"user\" FROM affiliations WHERE node=$1 AND affiliation='owner'", [ node ], cb2
        , (res, cb2) ->
            cb2 null, res.rows.map((row) ->
                row.user
            )
        ], cb

    writeItem: (publisher, node, id, item, cb) ->
        db = @db
        async.waterfall [ @nodeExists(node), (cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            isSet = res and res.rows and res.rows[0]
            if isSet
                db.query "UPDATE items SET xml=$1, published=CURRENT_TIMESTAMP WHERE node=$2 AND id=$3", [ item, node, id ], cb2
            else unless isSet
                db.query "INSERT INTO items (node, id, xml, published) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)", [ node, id, item ], cb2
        ], cb

    deleteItem: (node, itemId, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "DELETE FROM items WHERE node=$1 AND id=$2", [ node, itemId ], cb2
        , (res, cb2) ->
            if res.rowCount < 1
                cb2 new errors.NotFound("No such item")
            else
                cb2 null
        ], cb

    ##
    # sorted by time
    getItemIds: (node, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT id FROM items WHERE node=$1 ORDER BY published DESC", [ node ], cb2
        , (res, cb2) ->
            ids = res.rows.map((row) ->
                row.id
            )
            cb2 null, ids
        ], cb

    getItem: (node, id, cb) ->
        db = @db
        async.waterfall [(cb2) ->
            db.query "SELECT xml FROM items WHERE node=$1 AND id=$2", [ node, id ], cb2
        , (res, cb2) ->
            if res and res.rows and res.rows[0]
                cb2 null, res.rows[0].xml
            else
                cb2 new errors.NotFound("No such item")
        ], cb

    ##
    # @param itemCb {Function} itemCb({ node: String, id: String, item: Element })
    getUpdatesByTime: (subscriber, timeStart, timeEnd, itemCb, cb) ->
        conditions = [ "node IN (SELECT node FROM subscriptions WHERE \"user\"=$1 AND subscription='subscribed')" ]
        params = [ subscriber ]
        i = 1
        if timeStart
            conditions.push "published >= $" + (++i) + "::timestamp"
            params.push timeStart
        if timeEnd
            conditions.push "published <= $" + (++i) + "::timestamp"
            params.push timeEnd
        q = @db.query("SELECT id, node, xml FROM items WHERE " + conditions.join(" AND ") + " ORDER BY published ASC", params)
        q.on "row", (row) ->
            if item
                itemCb
                    node: row.node
                    id: row.id
                    item: row.xml


        q.on "error", (err_) ->
            err = err_

        q.on "end", ->
            cb err

    ##
    # Config management
    ##

    getConfig: (node, cb) ->
        db = @db
        async.waterfall [ @nodeExists(node), (cb2) ->
            db.query "SELECT \"key\", \"value\" FROM node_config WHERE node=$1", [ node ], cb2
        , (res, cb2) ->
            if res.rows
                config = {}
                res.rows.forEach (row) ->
                    config[row.key] = row.value

                cb2 null, config
            else
                cb2 new errors.NotFound("No such node")
        ], cb

    setConfig: (node, config, cb) ->
        db = @db
        console.log "setConfig " + node + ": " + require("util").inspect(config)
        async.waterfall [ @nodeExists(node), (cb2) ->
        	# If user supplied only partial information, old/default
            # values will be added by controller. That way we can just
            # INSERT later.
            db.query "DELETE FROM node_config WHERE node=$1", [ node ], cb2
        , (cb2) ->
            async.parallel(
                for own key, value of config
                    (cb3) ->
                		# Do not set configuration fields that have:
                		# * not been specified
                        # * no default config
                        if value == "" or value
                            db.query "INSERT INTO node_config (key, value, node) " + "VALUES ($1, $2, $3)"
                            , [ key, value, node ]
                            , cb3
            , cb2)
        ], cb


