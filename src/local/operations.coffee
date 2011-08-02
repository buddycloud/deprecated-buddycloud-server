async = require('async')
uuid = require('node-uuid')
errors = require('../errors')

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
        console.log "BrowseInfo run"
        cb()

class Register extends ModelOperation
    # TODO: overwrite @run() and check if this component is
    # authoritative for the requesting user's domain
    transaction: (t, cb) ->
        user = @req.actor
        listener = @req.sender
        async.series(for own nodeType, config in defaultConfiguration(user)
            do (nodeType, config) ->
                (cb2) ->
                    node = "/user/#{user}/#{nodeType}"
                    console.log "creating #{node}"
                    async.series [(cb3) ->
                        t.createNode node, cb3
                    , (cb3) ->
                        t.setAffiliation node, user, 'owner', cb3
                    , (cb3) ->
                        t.setSubscription node, user, listener, 'subscribed', cb3
                    , (cb3) ->
                        t.setConfig node, config, cb3
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
                unless item.id?
                    item.id = uuid()
                t.writeItem @req.node, item.id, @req.actor, item.el, cb2
        ), (err) ->
            if err
                cb err
            else
                cb null
        )

    notification: ->
        operation: 'publish-node-items'
        node: @req.node
        items: @req.items

class Subscribe extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.setSubscription @req.node, @req.actor, @req.sender, 'subscribed', (err) =>
            t.setAffiliation @req.node, @req.actor, 'member', (err) ->
                cb err

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

class ManageNodeAffiliations extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.subscriptions.map(({user, subscription}) =>
            (cb2) =>
                t.setSubscription @req.node, user, null, subscription, cb2
        ), cb

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
    'browse-node-info': undefined
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

exports.run = (router, request) ->
    opName = request.operation()
    unless opName
        # No operation specified, reply immediately
        request.reply()
        return

    opClass = OPERATIONS[opName]
    unless opClass
        console.error "Unimplemented operation #{opName}"
        console.log request: request
        request.replyError(new errors.FeatureNotImplemented("Unimplemented operation #{opName}"))
        return

    console.log "Creating operation #{opName}"
    op = new opClass(router, request)
    op.run (error, result) ->
        console.log "operation ran: #{error}, #{result}"
        if error
            request.replyError error
        else
            console.log "replying for #{opName}"
            request.reply result

            notification = op.notification?()
            if notification
                console.log "notifying for #{opName}"
                new Notify(router, notification).run (err) ->
                    if err
                        console.error("Error running notifications: #{err}")

