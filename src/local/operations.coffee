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


class PrivilegedOperation extends ModelOperation

    transaction: (t, cb) ->
        # TODO: Check privileges

        @privilegedTransaction t, cb


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

class Register extends ModelOperation
    # TODO: overwrite @run() and check if this component is
    # authoritative for the requesting user's domain
    transaction: (t, cb) ->
        console.log 'Register cb': cb
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


class Publish extends PrivilegedOperation
    requiredAffiliation: 'publisher'

    privilegedTransaction: (t, cb) ->
        # TODO: normalize
        async.series(@req.items.map((item) =>
            (cb2) =>
                async.waterfall [(cb3) =>
                    unless item.id?
                        item.id = uuid()
                        cb3 null, null
                    else
                        t.getItem @req.node, item.id, cb3
                , (oldItem, cb3) =>
                    normalizeItem @req, oldItem, item, cb3
                , (newItem, cb3) =>
                    t.writeItem @req.node, newItem.id, @req.actor, newItem.el, cb3
                ], cb2
        ), (err) ->
            if err
                cb err
            else
                cb null
        )

    notification: ->
        event: 'publish-node-items'
        node: @req.node
        items: @req.items

class Subscribe extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.setSubscription @req.node, @req.actor, @req.sender, 'subscribed', (err) =>
            t.setAffiliation @req.node, @req.actor, 'member', (err) =>
                cb err,
                    user: @req.actor
                    subscription: 'subscribed'

    notification: ->
        event: 'subscriptions-updated'
        node: @req.node
        subscriptions: [{
            user: @req.actor
            subscription: 'subscribed'
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
        event: 'subscriptions-updated'
        node: @req.node
        subscriptions: [{
            user: @req.actor
            subscription: 'unsubscribed'
        }]


class RetrieveItems extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        node = @req.node
        t.getItemIds node, (err, ids) ->
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
                    # TODO: apply RSM to ids

                    # Annotate results array
                    results.node = node
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
        t.getSubscriptions @req.actor, cb

class RetrieveUserAffiliations extends ModelOperation
    transaction: (t, cb) ->
        t.getAffiliations @req.actor, cb

class RetrieveNodeSubscriptions extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        t.getSubscribers @req.node, cb

class RetrieveNodeAffiliations extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        t.getAffiliated @req.node, cb

class ManageNodeSubscriptions extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.subscriptions.map(({user, subscription}) =>
            (cb2) =>
                t.setSubscription @req.node, user, null, subscription, cb2
        ), cb

    notification: ->
        event: 'subscriptions-updated'
        node: @req.node
        subscriptions: @req.subscriptions.map ({user, subscription}) =>
            { user, subscription }

class ManageNodeAffiliations extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.affiliations.map(({user, affiliation}) =>
            (cb2) =>
                t.setAffiliation @req.node, user, affiliation, cb2
        ), cb


    notification: ->
        event: 'affiliations-updated'
        node: @req.node
        subscriptions: @req.affiliations.map ({user, affiliation}) =>
            { user, affiliation }

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
        event: 'node-config-updated'
        node: @req.node
        config: @req.config


class PushInbox extends ModelOperation
    transaction: (t, cb) ->
        async.waterfall [(cb2) =>
            async.filter @opts, (update, cb3) ->
                if update.type is 'subscription' and update.listener?
                    # Was successful remote subscription attempt
                    t.createNode update.node, (err, created) ->
                        cb3 err, true
                else
                    # Just an update, to be cached locally?
                    t.nodeExists update.node, (err, exists) ->
                        cb3 err, exists
            , cb2
        , (updates, cb2) =>
            async.forEach updates, (update, cb3) ->
                switch update.type
                    when 'items'
                        {node, items} = update
                        async.forEach items, (item, cb4) ->
                            {id, el} = item
                            # FIXME: refactor out
                            author = el?.is('entry') and
                                el.getChild('author')?.getChild('uri')
                            if author and (m = /^acct:(.+)/)
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
                notification = Object.create(@req,
                    listener: value: listener
                )
                @router.notify notification

OPERATIONS =
    'browse-node-info': BrowseNodeInfo
    'browse-info': BrowseInfo
    'register-user': Register
    'publish-node-items': Publish
    'subscribe-node': Subscribe
    'unsubscribe-node': Unsubscribe
    'retrieve-node-items': RetrieveItems
    'retract-node-items': RetractItems
    'retrieve-user-subscriptions': RetrieveUserSubscriptions
    'retrieve-user-affiliations': RetrieveUserAffiliations
    'retrieve-node-subscriptions': RetrieveNodeSubscriptions
    'retrieve-node-affiliations': RetrieveNodeAffiliations
    'manage-node-subscriptions': ManageNodeSubscriptions
    'manage-node-affiliations': ManageNodeAffiliations
    'manage-node-configuration': ManageNodeConfiguration
    'push-inbox': PushInbox

exports.run = (router, request, cb) ->
    opName = request.operation()
    unless opName
        # No operation specified, reply immediately
        return cb()

    opClass = OPERATIONS[opName]
    unless opClass
        console.error "Unimplemented operation #{opName}"
        console.log request: request
        return cb(new errors.FeatureNotImplemented("Unimplemented operation #{opName}"))

    console.log "Creating operation #{opName}, cb=#{cb}"
    op = new opClass(router, request)
    op.run (error, result) ->
        console.log "operation ran: #{error}, #{result}"
        if error
            cb error
        else
            # Successfully done
            console.log "replying for #{opName}"
            cb null, result

            # Run notifications
            notification = op.notification?()
            if notification
                console.log "notifying for #{opName}"
                new Notify(router, notification).run (err) ->
                    if err
                        console.error("Error running notifications: #{err}")

