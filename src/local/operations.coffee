async = require('async')
uuid = require('node-uuid')
errors = require('../errors')
NS = require('../xmpp/ns')
{normalizeItem} = require('../normalize')

runTransaction = null
exports.setModel = (model) ->
    runTransaction = model.transaction

defaultConfiguration = (user) ->
    posts:
        title: "#{user} Channel Posts"
        description: "A buddycloud channel"
        accessModel: "open"
        publishModel: "subscribers"
        defaultAffiliation: "member"
    status:
        title: "#{user} Status Updates"
        description: "M000D"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geoloc/previous':
        title: "#{user} Previous Location"
        description: "Where #{user} has been before"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geoloc/current':
        title: "#{user} Current Location"
        description: "Where #{user} is at now"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geoloc/next':
        title: "#{user} Next Location"
        description: "Where #{user} intends to go"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    subscriptions:
        title: "#{user} Subscriptions"
        description: ""
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (@router, @req) ->

    run: (cb) ->
        cb new errorsFeature.NotImplemented("Operation defined but not yet implemented")

class ModelOperation extends Operation
    run: (cb) ->
        runTransaction (err, t) =>
            if err
                return cb err

            @transaction t, (err, results) ->
                if err
                    console.error "Transaction rollback: #{err}"
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        console.log "committed"
                        cb null, results


    # Must be implemented by subclass
    transaction: (t, cb) ->
        cb null


AFFILIATIONS = [
    'outcast', 'none', 'member',
    'publisher', 'moderator', 'owner'
]
class PrivilegedOperation extends ModelOperation

    transaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            @fetchActorAffiliation t, cb2
        , (cb2) =>
            @fetchNodeConfig t, cb2
        , (cb2) =>
            @checkRequiredAffiliation t, cb2
        , (cb2) =>
            @checkAccessModel t, cb2
        ], (err) =>
            if err
                return cb err

            @privilegedTransaction t, cb

    fetchActorAffiliation: (t, cb) ->
        unless @req.node
            return cb()

        # TODO: actor no user? check if listener!
        t.getAffiliation @req.node, @req.actor, (err, affiliation) =>
            if err
                return cb err

            @actorAffiliation = affiliation or @none
            console.log 'actorAffiliation', @actorAffiliation
            cb()

    fetchNodeConfig: (t, cb) ->
        unless @req.node
            return cb()

        t.getConfig @req.node, (err, config) =>
            if err
                return cb err

            @nodeConfig = config
            cb()

    checkAccessModel: (t, cb) ->
        # Deny any outcast
        if @actorAffiliation is 'outcast'
            return cb new errors.Forbidden("Outcast")

        # Set default according to node config
        unless @requiredAffiliation
            if @nodeConfig.accessModel is 'open'
                # Open nodes allow anyone
                @requiredAffiliation = 'none'
            else
                # For all other access models, actor has to be member
                @requiredAffiliation = 'member'

        cb()

    checkRequiredAffiliation: (t, cb) ->
        if AFFILIATIONS.indexOf(@actorAffiliation) >= AFFILIATIONS.indexOf(@requiredAffiliation)
            cb()
        else
            cb new errors.Forbidden("Requires affiliation #{@requiredAffiliation}")

    # Used by Publish operation
    checkPublishModel: (t, cb) ->
        pass = false
        switch @nodeConfig.publishModel
            when 'open'
                pass = true
            when 'members'
                pass = (AFFILIATIONS.indexOf(@actorAffiliation) >= 'member')
            when 'publishers'
                pass = (AFFILIATIONS.indexOf(@actorAffiliation) >= 'publishers')
            else
                # Owners can always post
                pass = (@actorAffiliation is 'owner')

        if pass
            cb()
        else if @nodeConfig.publishModel is 'subscribers'
            # Special handling because subscription state must be
            # fetched
            t.getSubscription @req.node, @req.actor, (err, subscription) ->
                if !err and subscription is 'subscribed'
                    cb()
                else
                    cb err or new errors.Forbidden("Only subscribers may publish")
        else
            cb new errors.Forbidden("Only #{@nodeConfig.publishModel} may publish")

class BrowseInfo extends Operation

    run: (cb) ->
        cb null,
            features: [
                NS.DISCO_INFO, NS.DISCO_ITEMS,
                NS.REGISTER,
                NS.PUBSUB, NS.PUBSUB_OWNER
            ]
            identities: [{
                category: "pubsub"
                type: "service"
                name: "XEP-0060 service"
            }, {
                category: "pubsub"
                type: "channels"
                name: "Channels service"
            }, {
                category: "pubsub"
                type: "inbox"
                name: "Channels inbox service"
            }]


class BrowseNodeInfo extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.getConfig @req.node, (err, config) =>
            cb err,
                node: @req.node
                features: [
                    NS.DISCO_INFO, NS.DISCO_ITEMS,
                    NS.REGISTER,
                    NS.PUBSUB, NS.PUBSUB_OWNER
                ]
                identities: [{
                    category: "pubsub"
                    type: "leaf"
                    name: "XEP-0060 node"
                }, {
                    category: "pubsub"
                    type: "channel"
                    name: "buddycloud channel"
                }]
                config: config

class BrowseNodes extends ModelOperation
    transaction: (t, cb) ->
        rsm = @req.rsm
        t.listNodes (err, results) =>
            if err
                return cb err

            results = rsm.cropResults(results, 'node')
            results.forEach (item) =>
                item.jid = @req.me
                item.name ?= item.title
            cb null, results

class BrowseNodesItems extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        t.getItemIds @req.node, (err, ids) =>
            if err
                return cb err

            # Apply RSM
            ids = @req.rsm.cropResults ids
            results = ids.map (id) =>
                { name: id, jid: @req.me, node: @req.node }
            results.node = @req.node
            results.rsm = @req.rsm
            cb null, results

class Register extends ModelOperation
    # TODO: overwrite @run() and check if this component is
    # authoritative for the requesting user's domain
    transaction: (t, cb) ->
        user = @req.actor
        listener = @req.sender
        async.parallel(for own nodeType, config of defaultConfiguration(user)
            do (nodeType, config) ->
                (cb2) ->
                    console.log 'Register cb2': cb2
                    node = "/user/#{user}/#{nodeType}"
                    console.log "creating #{node}"
                    created = true
                    async.waterfall [(cb3) ->
                        t.createNode node, cb3
                    , (created_, cb3) ->
                        console.log createNode: arguments
                        created = created_
                        t.setAffiliation node, user, 'owner', cb3
                    , (cb3) ->
                        console.log setAffiliation: arguments
                        t.setSubscription node, user, listener, 'subscribed', cb3
                    , (cb3) ->
                        console.log setSubscription: arguments
                        # if already present, don't overwrite config
                        if created
                            t.setConfig node, config, cb3
                        else
                            cb3 null
                    ], cb2
        , (err) ->
            cb err
        )


class CreateNode extends ModelOperation
    run: (cb) ->
        nodePrefix = "/user/#{@req.actor}/"
        if @req.node.indexOf(nodePrefix) == 0
            super
        else
            cb new errors.Forbidden("You can only create nodes under #{nodePrefix}")

    transaction: (t, cb) ->
        t.createNode @req.node, cb


class Publish extends PrivilegedOperation
    # checks affiliation with @checkPublishModel below

    privilegedTransaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            @checkPublishModel t, cb2
        , (cb2) =>
            async.series @req.items.map((item) =>
                (cb3) =>
                    async.waterfall [(cb4) =>
                        unless item.id?
                            item.id = uuid()
                            cb4 null, null
                        else
                            t.getItem @req.node, item.id, (err, item) ->
                                if err and err.constructor is errors.NotFound
                                    cb4 null, null
                                else
                                    cb4 err, item
                    , (oldItem, cb4) =>
                        normalizeItem @req, oldItem, item, cb4
                    , (newItem, cb4) =>
                        t.writeItem @req.node, newItem.id, @req.actor, newItem.el, (err) ->
                            cb4 err, newItem.id
                    ], cb3
            ), cb2
        ], cb

    notification: ->
        [{
            type: 'items'
            node: @req.node
            items: @req.items
        }]

class Subscribe extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        @affiliation = @req.config?.defaultAffiliation or 'member'
        t.setSubscription @req.node, @req.actor, @req.sender, 'subscribed', (err) =>
            t.setAffiliation @req.node, @req.actor, @affiliation, (err) =>
                cb err,
                    user: @req.actor
                    subscription: 'subscribed'

    notification: ->
        [{
            type: 'subscription'
            node: @req.node
            user: @req.actor
            subscription: 'subscribed'
        }, {
            type: 'affiliation'
            node: @req.node
            user: @req.actor
            affiliation: @affiliation
        }]

##
# Not privileged as anybody should be able to unsubscribe him/herself
class Unsubscribe extends ModelOperation
    transaction: (t, cb) ->
        t.setSubscription @req.node, @req.actor, @req.sender, 'none', (err) =>
            t.getAffiliation @req.node, @req.actor, (err, affiliation) =>
                if not err and affiliation is 'member'
                    t.setAffiliation @req.node, @req.actor, 'none', cb
                else
                    cb err

    notification: ->
        [{
            type: 'subscription'
            node: @req.node
            user: @req.actor
            subscription: 'unsubscribed'
        }]


class RetrieveItems extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        node = @req.node
        rsm = @req.rsm
        t.getItemIds node, (err, ids) ->
            # Apply RSM
            ids = rsm.cropResults ids

            # Fetching actual items
            async.series ids.map((id) ->
                (cb2) ->
                    t.getItem node, id, (err, el) ->
                        if err
                            return cb2 err

                        cb2 null,
                            id: id
                            el: el
            ), (err, results) ->
                if err
                    cb err
                else
                    # Annotate results array
                    results.node = node
                    results.rsm = rsm
                    cb null, results

class RetractItems extends PrivilegedOperation
    # TODO: let users remove their own posts
    requiredAffiliation: 'moderator'

    privilegedTransaction: (t, cb) ->
        node = @req.node
        async.series @req.items.map((id) ->
            (cb2) ->
                t.deleteItem node, id, cb2
        ), (err) ->
            cb err

class RetrieveUserSubscriptions extends ModelOperation
    transaction: (t, cb) ->
        rsm = @req.rsm
        t.getSubscriptions @req.actor, (err, subscriptions) ->
            if err
                return cb err

            subscriptions = rsm.cropResults subscriptions, 'node'
            cb null, subscriptions

class RetrieveUserAffiliations extends ModelOperation
    transaction: (t, cb) ->
        rsm = @req.rsm
        t.getAffiliations @req.actor, (err, affiliations) ->
            if err
                return cb err

            affiliations = rsm.cropResults affiliations, 'node'
            cb null, affiliations

class RetrieveNodeSubscriptions extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        rsm = @req.rsm
        t.getSubscribers @req.node, (err, subscriptions) ->
            if err
                return cb err

            subscriptions = rsm.cropResults subscriptions, 'user'
            cb null, subscriptions

class RetrieveNodeAffiliations extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        rsm = @req.rsm
        t.getAffiliated @req.node, (err, affiliations) ->
            if err
                return cb err

            affiliations = rsm.cropResults affiliations, 'user'
            cb null, affiliations

class RetrieveNodeConfiguration extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.getConfig @req.node, cb


class ManageNodeSubscriptions extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.subscriptions.map(({user, subscription}) =>
            (cb2) =>
                t.setSubscription @req.node, user, null, subscription, cb2
        ), cb

    notification: ->
        @req.subscriptions.map ({user, subscription}) =>
            {
                type: 'subscription'
                node: @req.node
                user
                subscription
            }

class ManageNodeAffiliations extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.affiliations.map(({user, affiliation}) =>
            (cb2) =>
                t.setAffiliation @req.node, user, affiliation, cb2
        ), cb


    notification: ->
        @req.affiliations.map ({user, affiliation}) =>
            {
                type: 'affiliation'
                node: @req.node
                user
                affiliation
            }

ALLOWED_ACCESS_MODELS = ['open', 'whitelist', 'authorize']
ALLOWED_PUBLISH_MODELS = ['open', 'subscribers', 'publishers']

class ManageNodeConfiguration extends PrivilegedOperation
    requiredAffiliation: 'owner'

    run: (cb) ->
        # Validate some config
        if @req.config.accessModel? and
           ALLOWED_ACCESS_MODELS.indexOf(@req.config.accessModel) < 0
            cb new errors.BadRequest("Invalid access model")
        else if @req.config.publishModel? and
           ALLOWED_PUBLISH_MODELS.indexOf(@req.config.publishModel) < 0
            cb new errors.BadRequest("Invalid publish model")
        else
            # All is well, actually run
            super(cb)

    privilegedTransaction: (t, cb) ->
        t.setConfig @req.node, @req.config, cb

    notification: ->
        [{
            type: 'config'
            node: @req.node
            config: @req.config
        }]

class ReplayArchive extends ModelOperation
    transaction: (t, cb) ->
        t.walkListenerArchive @req.sender, @req.start, @req.end, (results) =>
            console.log iter: results
            @sendNotification results
        , cb

    sendNotification: (results) ->
        notification = Object.create(results)
        notification.listener = @req.sender
        @router.notify notification

class PushInbox extends ModelOperation
    transaction: (t, cb) ->
        async.waterfall [(cb2) =>
            console.log updates: @req
            async.filter @req, (update, cb3) ->
                if update.type is 'subscription' and update.listener?
                    # Was successful remote subscription attempt
                    t.createNode update.node, (err, created) ->
                        cb3 not err
                else
                    # Just an update, to be cached locally?
                    t.nodeExists update.node, (err, exists) ->
                        cb3 (not err) and exists
            , (updates) ->
                cb2 null, updates
        , (updates, cb2) =>
            console.log filteredUpdates: updates
            async.forEach updates, (update, cb3) ->
                switch update.type
                    when 'items'
                        {node, items} = update
                        async.forEach items, (item, cb4) ->
                            {id, el} = item
                            # FIXME: refactor out
                            author = el?.is('entry') and
                                el.getChild('author')?.getChild('uri')?.getText()
                            if author and (m = /^acct:(.+)/.exec(author))
                                author = m[1]
                            t.writeItem node, id, author, el, cb4
                        , cb3

                    when 'subscription'
                        {node, user, listener, subscription} = update
                        t.setSubscription node, user, listener, subscription, cb3

                    when 'affiliation'
                        {node, user, affiliation} = update
                        t.setAffiliation node, user, affiliation, cb3

                    when 'config'
                        {node, config} = update
                        t.setConfig node, config, cb3

                    else
                        cb3 new errors.InternalServerError("Bogus push update type: #{update.type}")
            , cb2
            # Memorize updates for notifications, same format:
            @notification = ->
                updates
            # TODO: no subscriptions left? DELETE NODE!
        ], cb


class Notify extends ModelOperation
    transaction: (t, cb) ->
        # TODO: walk in batches
        console.log notifyNotification: @req
        t.getNodeListeners @req.node, (err, listeners) =>
            if err
                return cb err
            for listener in listeners
                console.log "listener: #{listener}"
                notification = Object.create(@req)
                notification.listener = listener
                @router.notify notification
            cb()

OPERATIONS =
    'browse-info': BrowseInfo
    'browse-node-info': BrowseNodeInfo
    'browse-nodes': BrowseNodes
    'browse-nodes-items': BrowseNodesItems
    'register-user': Register
    'create-node': CreateNode
    'publish-node-items': Publish
    'subscribe-node': Subscribe
    'unsubscribe-node': Unsubscribe
    'retrieve-node-items': RetrieveItems
    'retract-node-items': RetractItems
    'retrieve-user-subscriptions': RetrieveUserSubscriptions
    'retrieve-user-affiliations': RetrieveUserAffiliations
    'retrieve-node-subscriptions': RetrieveNodeSubscriptions
    'retrieve-node-affiliations': RetrieveNodeAffiliations
    'retrieve-node-configuration': RetrieveNodeConfiguration
    'manage-node-subscriptions': ManageNodeSubscriptions
    'manage-node-affiliations': ManageNodeAffiliations
    'manage-node-configuration': ManageNodeConfiguration
    'replay-archive': ReplayArchive
    'push-inbox': PushInbox

exports.run = (router, request, cb) ->
    opName = request.operation
    unless opName
        # No operation specified, reply immediately
        return cb()

    opClass = OPERATIONS[opName]
    unless opClass
        console.error "Unimplemented operation #{opName}"
        console.log request: request
        return cb(new errors.FeatureNotImplemented("Unimplemented operation #{opName}"))

    console.log "Creating operation #{opName}, cb=#{cb}"
    console.log request: request
    op = new opClass(router, request)
    op.run (error, result) ->
        console.log "operation ran: #{error}, #{result}"
        if error
            cb error
        else
            # Successfully done
            console.log "replying for #{opName}"
            try
                cb null, result
            catch e
                console.error e.stack or e

            # Run notifications
            notification = op.notification?()
            if notification
                console.log "notifying for #{opName}"

                for own node, notifications of groupByNode(notification)
                    notification.node = node
                    new Notify(router, notification).run (err) ->
                        if err
                            console.error("Error running notifications: #{err}")

groupByNode = (updates) ->
    result = {}
    for update in updates
        unless result.hasOwnProperty(update.node)
            result[update.node] = []
        result[update.node].push update
    result
