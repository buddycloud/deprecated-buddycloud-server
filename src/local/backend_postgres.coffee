pg = require("pg")
async = require("async")
ltx = require("ltx")
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
        # Can be dropped in a step() sequence to validate presence of a node.
        nodeExists: (node) ->
            db = @db
            ->
                async.series [ ->
                    db.query "SELECT node FROM nodes WHERE node=$1", [ node ], this
                , (err, res) ->
                    if err
                        throw err
                    if res.rowCount < 1
                        throw new errors.NotFound("Node does not exist")
                    this()
                , this]

        createNode: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node FROM nodes WHERE node=$1", [ node ], this
            , (err, res) ->
                if err
                    throw err
                if res.rowCount > 0
                    # Node already exists: ignore
                    this(null)
                else
                    db.query "INSERT INTO nodes (node) VALUES ($1)", [ node ], this
            , cb]

        ##
        # cb(err, [{ node: String, title: String }])
        listNodes: (cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node FROM nodes WHERE node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", this
            , (err, res) ->
                if err
                    throw err
                nodes = res.rows.map (row) ->
                    node: row.node
                    title: row.title
                this null, nodes
            , cb]

        listNodesByUser: (user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node FROM nodes WHERE position('/user/' || $1 IN node) = 1 AND node IN (SELECT node FROM node_config WHERE \"key\"='accessModel' AND \"value\"='open') " + "ORDER BY node ASC", [ user ], this
            , (err, res) ->
                if err
                    throw err
                nodes = res.rows.map (row) ->
                    node: row.node
                    title: row.title
                this null, nodes
            , cb]

        ##
        # Subscription management
        ##

        getSubscription: (node, user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND user=$2", [ node, user ], this
            , (err, res) ->
                if err
                    throw err
                this null, (res.rows[0] and res.rows[0].subscription) or "none"
            , cb]

        setSubscription: (node, user, subscription, cb) ->
            db = @db
            async.series [ @nodeExists(node), (err) ->
                if err
                    throw err
                db.query "SELECT subscription FROM subscriptions WHERE node=$1 AND user=$2", [ node, user ], this
            , (err, res) ->
                if err
                    throw err
                isSet = res and res.rows and res.rows[0]
                toDelete = not subscription or subscription == "none"
                if isSet and not toDelete
                    db.query "UPDATE subscriptions SET subscription=$1 WHERE node=$2 AND \"user\"=$3", [ subscription, node, user ], this
                else if not isSet and not toDelete
                    db.query "INSERT INTO subscriptions (node, \"user\", subscription) VALUES ($1, $2, $3)", [ node, user, subscription ], this
                else if isSet and toDelete
                    db.query "DELETE FROM subscriptions WHERE node=$1 AND \"user\"=$2", [ node, user ], this
                else if not isSet and toDelete
                    cb null
                else
                    cb new Error('Invalid subscription transition')
            , cb]

        getSubscribers: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT \"user\", subscription FROM subscriptions WHERE node=$1", [ node ], this
            , (err, res) ->
                if err
                    throw err
                subscribers = []
                res.rows.forEach (row) ->
                    subscribers.push
                        user: row.user
                        subscription: row.subscription

                this null, subscribers
            , cb]

        getSubscriptions: (user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node, subscription FROM subscriptions WHERE \"user\"=$1", [ user ], this
            , (err, res) ->
                if err
                    throw err
                subscriptions = []
                res.rows.forEach (row) ->
                    subscriptions.push
                        node: row.node
                        subscription: row.subscription

                this null, subscriptions
            , cb]

        getAllSubscribers: (cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT DISTINCT \"user\" FROM subscriptions", this
            , (err, res) ->
                if err
                    throw err
                subscribers = []
                res.rows.forEach (row) ->
                    subscribers.push row.user

                this null, subscribers
            , cb]

        getPendingNodes: (user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node FROM affiliations WHERE affiliation = 'owner' AND user = $1 AND EXISTS (SELECT user FROM subscriptions WHERE subscription = 'pending' AND node = affiliations.node)", [ user ], this
            , (err, res) ->
                if err
                    throw err
                this null, res.rows.map((row) ->
                    row.node
                )
            , cb]

        getPending: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT user FROM subscriptions WHERE subscription = 'pending' AND node = $1", [ node ], this
            , (err, res) ->
                if err
                    throw err
                this null, res.rows.map((row) ->
                    row.user
                )
            , cb]

        ##
        # Affiliation management
        ##

        getAffiliation = (node, user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND user=$2", [ node, user ], this
            , (err, res) ->
                if err
                    throw err
                this null, (res.rows[0] and res.rows[0].affiliation) or "none"
            , cb]

        setAffiliation = (node, user, affiliation, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT affiliation FROM affiliations WHERE node=$1 AND user=$2", [ node, user ], this
            , (err, res) ->
                if err
                    throw err
                isSet = res and res.rows and res.rows[0]
                toDelete = not affiliation or affiliation == "none"
                if isSet and not toDelete
                    db.query "UPDATE affiliations SET affiliation=$1 WHERE node=$2 AND \"user\"=$3", [ affiliation, node, user ], this
                else if not isSet and not toDelete
                    db.query "INSERT INTO affiliations (node, \"user\", affiliation) VALUES ($1, $2, $3)", [ node, user, affiliation ], this
                else if isSet and toDelete
                    db.query "DELETE FROM affiliations WHERE node=$1 AND \"user\"=$2", [ node, user ], this
                else if not isSet and toDelete
                    cb null
            , cb]

        getAffiliations: (user, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT node, affiliation FROM affiliations WHERE \"user\"=$1", [ user ], this
            , (err, res) ->
                if err
                    throw err
                affiliations = []
                res.rows.forEach (row) ->
                    affiliations.push
                        node: row.node
                        affiliation: row.affiliation

                this null, affiliations
            , cb]

        getAffiliated: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT \"user\", affiliation FROM affiliations WHERE node=$1", [ node ], this
            , (err, res) ->
                if err
                    throw err
                affiliations = []
                res.rows.forEach (row) ->
                    affiliations.push
                        user: row.user
                        affiliation: row.affiliation

                this null, affiliations
            , cb]

        getOwners: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT \"user\" FROM affiliations WHERE node=$1 AND affiliation='owner'", [ node ], this
            , (err, res) ->
                if err
                    throw err
                this null, res.rows.map((row) ->
                    row.user
                )
            , cb]

        writeItem: (publisher, node, id, item, cb) ->
            db = @db
            xml = item.toString()
            async.series [ @nodeExists(node), (err) ->
                if err
                    throw err
                db.query "SELECT id FROM items WHERE node=$1 AND id=$2", [ node, id ], this
            , (err, res) ->
                if err
                    throw err
                isSet = res and res.rows and res.rows[0]
                if isSet
                    db.query "UPDATE items SET xml=$1, published=CURRENT_TIMESTAMP WHERE node=$2 AND id=$3", [ xml, node, id ], this
                else unless isSet
                    db.query "INSERT INTO items (node, id, xml, published) VALUES ($1, $2, $3, CURRENT_TIMESTAMP)", [ node, id, xml ], this
            , cb]

        deleteItem: (node, itemId, cb) ->
            db = @db
            async.series [ ->
                db.query "DELETE FROM items WHERE node=$1 AND id=$2", [ node, itemId ], this
            , (err, res) ->
                if err
                    throw err
                if res.rowCount < 1
                    throw new errors.NotFound("No such item")
                this null
            , cb]

        ##
        # sorted by time
        getItemIds: (node, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT id FROM items WHERE node=$1 ORDER BY published DESC", [ node ], this
            , (err, res) ->
                if err
                    throw err
                ids = res.rows.map((row) ->
                    row.id
                )
                this null, ids
            , cb]

        getItem: (node, id, cb) ->
            db = @db
            async.series [ ->
                db.query "SELECT xml FROM items WHERE node=$1 AND id=$2", [ node, id ], this
            , (err, res) ->
                if err
                    throw err
                if res and res.rows and res.rows[0]
                    item = parseItem(res.rows[0].xml)
                    this null, item
                else
                    throw new errors.NotFound("No such item")
            , cb]

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
                item = parseItem(row.xml)
                if item
                    itemCb
                        node: row.node
                        id: row.id
                        item: item


            q.on "error", (err_) ->
                err = err_

            q.on "end", ->
                cb err

        ##
        # Config management
        ##

        getConfig: (node, cb) ->
            db = @db
            async.series [ @nodeExists(node), (err) ->
                if err
                    throw err
                db.query "SELECT \"key\", \"value\" FROM node_config WHERE node=$1", [ node ], this
            , (err, res) ->
                if err
                    throw err
                if res.rows
                    config = {}
                    res.rows.forEach (row) ->
                        config[row.key] = row.value

                    this null, config
                else
                    throw new errors.NotFound("No such node")
            , cb]

        setConfig: (node, config, cb) ->
            db = @db
            console.log "setConfig " + node + ": " + require("util").inspect(config)
            async.series [ @nodeExists(node), (err) ->
                if err
                    throw err

            	# If user supplied only partial information, old/default
                # values will be added by controller. That way we can just
                # INSERT later.
                db.query "DELETE FROM node_config WHERE node=$1", [ node ], this
            , (err) ->
                if err
                    throw err
                g = @parallel()
                for own key, value of config
            		# Do not set configuration fields that have:
            		# * not been specified
                    # * no default config
                    if value == "" or value
                        db.query "INSERT INTO node_config (key, value, node) " + "VALUES ($1, $2, $3)", [ key, value, node ], g
                g()
            , (err, res) ->
                if err
                    throw err
                this null
            , cb]

parseItem = (xml) ->
    try
        return ltx.parse(xml)
    catch e
        console.error "Parsing " + xml + ": " + e.stack
        return undefined

