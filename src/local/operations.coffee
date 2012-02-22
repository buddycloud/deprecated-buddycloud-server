logger = require('../logger').makeLogger 'local/operations'
{inspect} = require('util')
{getNodeUser, getNodeType} = require('../util')
async = require('async')
uuid = require('node-uuid')
errors = require('../errors')
NS = require('../xmpp/ns')
{normalizeItem} = require('../normalize')
{Element} = require('node-xmpp')

runTransaction = null
exports.setModel = (model) ->
    runTransaction = model.transaction

exports.checkCreateNode = null

defaultConfiguration = (user) ->
    posts:
        title: "#{user} Channel Posts"
        description: "A buddycloud channel"
        channelType: "personal"
        accessModel: "open"
        publishModel: "subscribers"
        defaultAffiliation: "member"
    status:
        title: "#{user} Status Updates"
        description: "M000D"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geo/previous':
        title: "#{user} Previous Location"
        description: "Where #{user} has been before"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geo/current':
        title: "#{user} Current Location"
        description: "Where #{user} is at now"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    'geo/next':
        title: "#{user} Next Location"
        description: "Where #{user} intends to go"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"
    subscriptions:
        title: "#{user} Subscriptions"
        description: "Browse my interests"
        accessModel: "open"
        publishModel: "publishers"
        defaultAffiliation: "member"

# user is "topic@domain" string
defaultTopicConfiguration = (user) =>
    posts:
        title: "#{user} Topic Channel"
        description: "All about #{user.split('@')?[0]}"
        channelType: "topic"
        accessModel: "open"
        publishModel: "subscribers"
        defaultAffiliation: "member"

NODE_OWNER_TYPE_REGEXP = /^\/user\/([^\/]+)\/?(.*)/

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (@router, @req) ->
        if @req.node? and
           (m = @req.node.match(NODE_OWNER_TYPE_REGEXP)) and
           m[2] is 'subscriptions'
            # Affords for specialized items handling in RetrieveItems and Publish
            @subscriptionsNodeOwner = m[1]

    run: (cb) ->
        cb new errorsFeature.NotImplemented("Operation defined but not yet implemented")

class ModelOperation extends Operation
    run: (cb) ->
        runTransaction (err, t) =>
            if err
                return cb err

            opName = @req.operation or "?"
            @transaction t, (err, results) ->
                if err
                    logger.warn "Transaction rollback: #{err}"
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        logger.debug "Operation #{opName} committed"
                        cb null, results


    # Must be implemented by subclass
    transaction: (t, cb) ->
        cb null


AFFILIATIONS = [
    'outcast', 'none', 'member',
    'publisher', 'moderator', 'owner'
]
isAffiliationAtLeast = (affiliation1, affiliation2) ->
    i1 = AFFILIATIONS.indexOf(affiliation1)
    i2 = AFFILIATIONS.indexOf(affiliation2)
    if i2 < 0
        false
    else
        i1 >= i2

class PrivilegedOperation extends ModelOperation

    transaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            @fetchActorAffiliation t, cb2
        , (cb2) =>
            @fetchNodeConfig t, cb2
        , (cb2) =>
            @checkAccessModel t, cb2
        , (cb2) =>
            @checkRequiredAffiliation t, cb2
        ], (err) =>
            if err
                return cb err

            @privilegedTransaction t, cb

    fetchActorAffiliation: (t, cb) ->
        unless @req.node
            return cb()

        if @req.actor.indexOf('@') >= 0
            t.getAffiliation @req.node, @req.actor, (err, affiliation) =>
                if err
                    return cb err

                @actorAffiliation = affiliation or 'none'
                cb()

        else
            # actor no user? check if listener!
            t.getListenerAffiliations @req.node, @req.actor, (err, affiliations) =>
                if err
                    return cb err

                @actorAffiliation = 'none'
                for affiliation in affiliations
                    if isAffiliationAtLeast affiliation, @actorAffiliation
                        @actorAffiliation = affiliation
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
        if not @requiredAffiliation? or
           isAffiliationAtLeast @actorAffiliation, @requiredAffiliation
            cb()
        else
            cb new errors.Forbidden("Requires affiliation #{@requiredAffiliation} (you are #{@actorAffiliation})")

    # Used by Publish operation
    checkPublishModel: (t, cb) ->
        pass = false
        switch @nodeConfig.publishModel
            when 'open'
                pass = true
            when 'members'
                pass = isAffiliationAtLeast @actorAffiliation, 'member'
            when 'publishers'
                pass = isAffiliationAtLeast @actorAffiliation, 'publisher'
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
    ##
    # See access control notice of RetrieveNodeConfiguration
    transaction: (t, cb) ->
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
        @fetchNodes t, (err, results) =>
            if err
                return cb err

            results = rsm.cropResults(results, 'node')
            results.forEach (item) =>
                item.jid = @req.me
            cb null, results

    fetchNodes: (t, cb) ->
        t.listNodes cb

class BrowseTopFollowedNodes extends BrowseNodes
    fetchNodes: (t, cb) ->
        max = @req.rsm.max or 10
        t.getTopFollowedNodes max, null, null, cb

class BrowseTopPublishedNodes extends BrowseNodes
    fetchNodes: (t, cb) ->
        max = @req.rsm.max or 10
        t.getTopPublishedNodes max, null, null, cb

class BrowseNodeItems extends PrivilegedOperation
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
    run: (cb) ->
        # check if this component is authoritative for the requesting
        # user's domain
        @router.authorizeFor @req.me, @req.actor, (err, valid) =>
            if err
                return cb err

            if valid
                # asynchronous super:
                ModelOperation::run.call @, cb
            else
                cb new errors.NotAllowed("This is not the authoritative buddycloud-server for your domain")

    transaction: (t, cb) ->
        user = @req.actor
        jobs = []
        for own nodeType, config of defaultConfiguration(user)
            # rescope loop variables:
            do (nodeType, config) =>
                jobs.push (cb2) =>
                    node = "/user/#{user}/#{nodeType}"
                    config.creationDate = new Date().toISOString()
                    @createNodeWithConfig t, node, config, cb2
        async.series jobs, (err) ->
            cb err

    createNodeWithConfig: (t, node, config, cb) ->
        user = @req.actor
        created = no
        async.waterfall [(cb2) ->
            logger.info "creating #{node}"
            t.createNode node, cb2
        , (created_, cb2) ->
            created = created_
            t.setAffiliation node, user, 'owner', cb2
        , (cb2) =>
            t.setSubscription node, user, @req.sender, 'subscribed', cb2
        , (cb2) ->
            # if already present, don't overwrite config
            if created
                t.setConfig node, config, cb2
            else
                cb2 null
        ], cb


class CreateNode extends ModelOperation
    transaction: (t, cb) ->
        nodeUser = getNodeUser @req.node
        unless nodeUser
            return cb new errors.BadRequest("Malformed node")
        if nodeUser.split("@")[0].length < 1
            return cb new errors.BadRequest("Malformed node name")
        isTopic = nodeUser isnt @req.actor
        nodePrefix = "/user/#{nodeUser}/"

        try
            opts =
                node: @req.node
                nodeUser: nodeUser
                actor: @req.actor
            unless exports.checkCreateNode?(opts)
                return cb new errors.NotAllowed("Node creation not allowed")
        catch e
            return cb e

        async.waterfall [(cb2) =>
            t.getOwnersByNodePrefix nodePrefix, cb2
        , (owners, cb2) =>
            if owners.length < 1 or owners.indexOf(@req.actor) >= 0
                # Either there are no owners yet, or the user is
                # already one of them.
                t.createNode @req.node, cb2
            else
                cb2 new errors.NotAllowed("Nodes with prefix #{nodePrefix} are already owned by #{owners.join(', ')}")
        , (created, cb2) =>
            if created
                # Worked, proceed
                cb2 null
            else
                # Already exists
                cb2 new errors.Conflict("Node #{@req.node} already exists")
        , (cb2) =>
            config = @req.config or {}
            config.creationDate = new Date().toISOString()

            # Pick config defaults
            if isTopic
                defaults = defaultTopicConfiguration nodeUser
            else
                defaults = defaultConfiguration nodeUser
            defaults = defaults[getNodeType @req.node]
            if defaults
                # Mix into config
                for own key, value of defaults
                    unless config
                        config = {}
                    # Don't overwrite existing
                    unless config[key]?
                        config[key] = value

            # Set
            t.setConfig @req.node, config, cb2
        , (cb2) =>
            t.setSubscription @req.node, @req.actor, @req.sender, 'subscribed', cb2
        , (cb2) =>
            t.setAffiliation @req.node, @req.actor, 'owner', cb2
        ], cb

class Publish extends PrivilegedOperation
    # checks affiliation with @checkPublishModel below

    privilegedTransaction: (t, cb) ->
        if @subscriptionsNode?
            return cb new errors.NotAllowed("The subscriptions node is automagically populated")

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
                        t.writeItem @req.node, newItem.id, newItem.el, (err) ->
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
    ##
    # Overwrites PrivilegedOperation#transaction() to use a different
    # permissions checking model, but still uses its methods.
    transaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            @fetchActorAffiliation t, cb2
        , (cb2) =>
            @fetchNodeConfig t, cb2
        , (cb2) =>
            if @nodeConfig.accessModel is 'authorize'
                @subscription = 'pending'
                # Immediately return:
                return cb2()

            @subscription = 'subscribed'
            unless isAffiliationAtLeast @actorAffiliation, @nodeConfig.defaultAffiliation
                # Less than current affiliation? Bump up to defaultAffiliation
                @affiliation = @nodeConfig.defaultAffiliation or 'member'

            @checkAccessModel t, cb2
        ], (err) =>
            if err
                return cb err

            @privilegedTransaction t, cb

    privilegedTransaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            t.setSubscription @req.node, @req.actor, @req.sender, @subscription, cb2
        , (cb2) =>
            if @affiliation
                t.setAffiliation @req.node, @req.actor, @affiliation, cb2
            else
                cb2()
        ], (err) =>
            cb err,
                user: @req.actor
                subscription: @subscription

    notification: ->
        ns = [{
                type: 'subscription'
                node: @req.node
                user: @req.actor
                subscription: @subscription
            }]
        if @affiliation
            ns.push
                type: 'affiliation'
                node: @req.node
                user: @req.actor
                affiliation: @affiliation
        ns

    moderatorNotification: ->
        if @subscription is 'pending'
            type: 'authorizationPrompt'
            node: @req.node
            user: @req.actor

##
# Not privileged as anybody should be able to unsubscribe him/herself
class Unsubscribe extends PrivilegedOperation
    transaction: (t, cb) ->
        if @req.node.indexOf("/user/#{@req.actor}/") == 0
            return cb new errors.Forbidden("You may not unsubscribe from your own nodes")

        async.waterfall [ (cb2) =>
            t.setSubscription @req.node, @req.actor, @req.sender, 'none', cb2
        , (cb2) =>
            @fetchActorAffiliation t, cb2
        , (cb2) =>
            @fetchNodeConfig t, cb2
        , (cb2) =>
            # only decrease if <= defaultAffiliation
            if isAffiliationAtLeast(@nodeConfig.defaultAffiliation, @actorAffiliation) and
               @actorAffiliation isnt 'outcast'
                @actorAffiliation = 'none'
                t.setAffiliation @req.node, @req.actor, 'none', cb2
            else
                cb2()
        ], cb

    notification: ->
        [{
            type: 'subscription'
            node: @req.node
            user: @req.actor
            subscription: 'none'
        }, {
            type: 'affiliation'
            node: @req.node
            user: @req.actor
            affiliation: @actorAffiliation
        }]


class RetrieveItems extends PrivilegedOperation
    run: (cb) ->
        if @subscriptionsNodeOwner?
            # Special case: only handle virtually when local server is
            # authoritative
            @router.authorizeFor @req.me, @subscriptionsNodeOwner, (err, valid) =>
                if err
                    return cb err

                if valid
                    # Patch in virtual items
                    @privilegedTransaction = @retrieveSubscriptionsItems

                # asynchronous super:
                PrivilegedOperation::run.call @, cb
        else
            super

    privilegedTransaction: (t, cb) ->
        node = @req.node
        rsm = @req.rsm

        if @req.itemIds?
            fetchItemIds = (cb2) =>
                cb2 null, @req.itemIds
        else
            fetchItemIds = (cb2) ->
                t.getItemIds node, cb2

        fetchItemIds (err, ids) ->
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

    ##
    # For /user/.../subscriptions
    #
    # <item id="koski@buddycloud.com">
    #    <query xmlns="http://jabber.org/protocol/disco#items" xmlns:pubsub="http://jabber.org/protocol/pubsub" xmlns:atom="http://www.w3.org/2005/Atom">
    #       <item jid="sandbox.buddycloud.com"
    #             node="/user/koski@buddycloud.com/posts"
    #             pubsub:affiliation="publisher">
    #         <atom:updated>2010-12-26T17:30:00Z</atom:updated>
    #       </item>
    #       <item jid="sandbox.buddycloud.com"
    #             node="/user/koski@buddycloud.com/geo/future"/>
    #       <item jid="sandbox.buddycloud.com"
    #             node="/user/koski@buddycloud.com/geo/current"/>
    #       <item jid="sandbox.buddycloud.com"
    #             node="/user/koski@buddycloud.com/geo/previous"/>
    #       <item jid="sandbox.buddycloud.com"
    #             node="/user/koski@buddycloud.com/mood"
    #             pubsub:affiliation="member"/>
    #    </query>
    #  </item>
    retrieveSubscriptionsItems: (t, cb) ->
        async.waterfall [ (cb2) =>
            t.getSubscriptions @subscriptionsNodeOwner, cb2
        , (subscriptions, cb2) =>
            # Group for item ids by followee:
            subscriptionsByFollowee = {}
            for subscription in subscriptions
                if (m = subscription.node.match(NODE_OWNER_TYPE_REGEXP))
                    followee = m[1]
                    unless subscriptionsByFollowee[followee]?
                        subscriptionsByFollowee[followee] = []
                    subscriptionsByFollowee[followee].push subscription
            # Prepare RSM suitable result set
            results = []
            for own followee, followeeSubscriptions of subscriptionsByFollowee
                results.push
                    id: followee
                    subscriptions: followeeSubscriptions
            # Sort for a stable traversal with multiple RSM'ed queries
            results.sort (result1, result2) ->
                if result1.id < result2.id
                    -1
                else if result1.id > result2.id
                    1
                else
                    0
            # Apply RSM
            results = @req.rsm.cropResults results, 'id'

            # get affiliations per node
            async.forEachSeries results, (result, cb3) =>
                async.forEach result.subscriptions, (subscription, cb4) =>
                    t.getAffiliation subscription.node, @subscriptionsNodeOwner, (err, affiliation) ->
                        subscription.affiliation ?= affiliation
                        cb4 err
                , cb3
            , (err) ->
                cb2 err, results
        , (results, cb2) =>
            # Transform to specified items format
            for item in results
                item.el = new Element('query',
                        xmlns: NS.DISCO_ITEMS
                        'xmlns:pubsub': NS.PUBSUB
                    )
                for subscription in item.subscriptions
                    itemAttrs =
                        jid: @subscriptionsNodeOwner
                        node: subscription.node
                    itemAttrs['pubsub:subscription'] ?= subscription.subscription
                    itemAttrs['pubsub:affiliation'] ?= subscription.affiliation
                    item.el.c('item', itemAttrs)
                delete item.subscriptions

            results.rsm = @req.rsm
            results.node = @req.node
            cb2 null, results
        ], cb


class RetractItems extends PrivilegedOperation
    privilegedTransaction: (t, cb) ->
        async.waterfall [ (cb2) =>
            if isAffiliationAtLeast @actorAffiliation, 'moderator'
                # Owners and moderators may remove any post
                cb2()
            else
                # Anyone may remove only their own posts
                @checkItemsAuthor t, cb2
        , (cb2) =>
            async.forEach @req.items, (id, cb3) =>
                    t.deleteItem @req.node, id, cb3
            , cb2
        ], cb

    checkItemsAuthor: (t, cb) ->
        async.forEachSeries @req.items, (id, cb2) =>
            t.getItem @req.node, id, (err, el) =>
                if err?.constructor is errors.NotFound
                    # Ignore non-existant item
                    return cb2()
                else if err
                    return cb2(err)

                # Check for post authorship
                author = el?.is('entry') and
                    el.getChild('author')?.getChild('uri')?.getText()
                if author is "acct:#{@req.actor}"
                    # Authenticated!
                    cb2()
                else
                    cb2 new errors.NotAllowed("You may not retract other people's posts")
        , cb

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
    ##
    # Allowed for anyone. We do not have hidden channels yet.
    #
    # * Even closed channels should be browsable so that subscription
    #   can be requested at all
    # * outcast shall not receive too much punishment (or glorification)
    transaction: (t, cb) ->
        t.getConfig @req.node, (err, config) ->
            # wrap into { config: ...} result
            cb err, { config }


class ManageNodeSubscriptions extends PrivilegedOperation
    requiredAffiliation: 'owner'

    privilegedTransaction: (t, cb) ->
        async.series @req.subscriptions.map(({user, subscription}) =>
            (cb2) =>
                async.waterfall [(cb3) =>
                    t.setSubscription @req.node, user, null, subscription, cb2
                , (cb3) =>
                    t.getAffiliation @req.node, user, cb3
                , (affiliation, cb3) =>
                    if affiliation is 'none'
                        t.getConfig @req.node, (error, config) =>
                            defaultAffiliation = config.defaultAffiliation or 'member'
                            t.setAffiliation @req.node, user, defaultAffiliation, cb3
                    else
                        cb3()
                ], cb2
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
                async.series [ (cb3) =>
                    t.getAffiliation @req.node, user, cb3
                , (oldAffiliation, cb3) =>
                    if oldAffiliation is affiliation
                        # No change
                        cb3()
                    else
                        if oldAffiliation isnt 'owner' and
                           affiliation is 'owner' and
                           @actorAffiliation isnt 'owner'
                            # Non-owner tries to elect a new owner!
                            cb3 new errors.Forbidden("You may not elect a new owner")
                        else
                            t.setAffiliation @req.node, user, affiliation, cb3
                ], cb2
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
        else if @req.config.creationDate?
            cb new errors.BadRequest("Cannot set creation date")
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

##
# Removes all subscriptions of the actor, call back with all remote
# subscriptions that the backends must then unsubscribe for.
#
# Two uses:
#
# * Rm subscriptions of an anonymous (temporary) user
# * TODO: Completely clear out a user account
class RemoveUser extends ModelOperation
    transaction: (t, cb) ->
        t.getUserRemoteSubscriptions @req.actor, (err, subscriptions) =>
            if err
                return cb(err)

            t.clearUserSubscriptions @req.actor, (err) =>
                cb err, subscriptions


class AuthorizeSubscriber extends PrivilegedOperation
    requiredAffiliation: 'moderator'

    privilegedTransaction: (t, cb) ->
        if @req.allow
            @subscription = 'subscribed'
            unless isAffiliationAtLeast @actorAffiliation, @nodeConfig.defaultAffiliation
                # Less than current affiliation? Bump up to defaultAffiliation
                @affiliation = @nodeConfig.defaultAffiliation or 'member'
        else
            @subscription = 'none'

        async.waterfall [ (cb2) =>
            t.setSubscription @req.node, @req.user, @req.sender, @subscription, cb2
        , (cb2) =>
            if @affiliation
                t.setAffiliation @req.node, @req.user, @affiliation, cb2
            else
                cb2()
        ], (err) ->
            cb err

    notification: ->
        ns = [{
                type: 'subscription'
                node: @req.node
                user: @req.user
                subscription: @subscription
            }]
        if @affiliation
            ns.push
                type: 'affiliation'
                node: @req.node
                user: @req.user
                affiliation: @affiliation
        ns

##
# MAM replay
# and authorization form query
#
# The RSM handling here respects only a <max/> value.
class ReplayArchive extends ModelOperation
    transaction: (t, cb) ->
        max = @req.rsm?.max or 50
        sent = 0

        async.waterfall [ (cb2) =>
            t.walkListenerArchive @req.sender, @req.start, @req.end, max, (results) =>
                if sent < max
                    results.sort (a, b) ->
                        if a.updated < b.updated
                            -1
                        else if a.updated > b.updated
                            1
                        else
                            0

                    results = results.slice(0, max - sent)
                    @sendNotification results
                    sent += results.length
            , cb2
        , (cb2) =>
            sent = 0
            t.walkModeratorAuthorizationRequests @req.sender, (req) =>
                if sent < max
                    req.type = 'authorizationPrompt'
                    @sendNotification req
                    sent++
            , cb2
        ], cb

    sendNotification: (results) ->
        notification = Object.create(results)
        notification.listener = @req.fullSender
        notification.replay = true
        @router.notify notification

class PushInbox extends ModelOperation
    transaction: (t, cb) ->
        async.waterfall [(cb2) =>
            logger.debug "pushUpdates: #{inspect @req}"
            async.filter @req, (update, cb3) ->
                if update.type is 'subscription' and update.listener?
                    # Was successful remote subscription attempt
                    t.createNode update.node, (err, created) ->
                        cb3 not err
                else
                    # Just an update, to be cached locally?
                    t.nodeExists update.node, (err, exists) ->
                        cb3 not err and exists
            , (updates) ->
                cb2 null, updates
        , (updates, cb2) =>
            logger.debug "pushFilteredUpdates: #{inspect updates}"
            async.forEach updates, (update, cb3) ->
                switch update.type
                    when 'items'
                        {node, items} = update
                        async.forEach items, (item, cb4) ->
                            {id, el} = item
                            t.writeItem node, id, el, cb4
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
        logger.debug "notifyNotification: #{inspect @req}"
        t.getNodeListeners @req.node, (err, listeners) =>
            if err
                return cb err

            # Always notify all users pertained by a subscription
            # notification, even if just unsubscribed.
            for update in @req
                if update.type is 'subscription' and
                   listeners.indexOf(update.user) < 0
                    listeners.push update.user

            for listener in listeners
                notification = Object.create(@req)
                notification.listener = listener
                @router.notify notification
            cb()

class ModeratorNotify extends ModelOperation
    transaction: (t, cb) ->
        # TODO: walk in batches
        logger.debug "moderatorNotifyNotification: #{inspect(@req)}"
        t.getNodeModeratorListeners @req.node, (err, listeners) =>
            if err
                return cb err
            for listener in listeners
                notification = Object.create(@req)
                notification.listener = listener
                @router.notify notification
            cb()

OPERATIONS =
    'browse-info': BrowseInfo
    'browse-node-info': BrowseNodeInfo
    'browse-nodes': BrowseNodes
    'browse-top-followed-nodes': BrowseTopFollowedNodes
    'browse-top-published-nodes': BrowseTopPublishedNodes
    'browse-node-items': BrowseNodeItems
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
    'remove-user': RemoveUser
    'confirm-subscriber-authorization': AuthorizeSubscriber
    'replay-archive': ReplayArchive
    'push-inbox': PushInbox

exports.run = (router, request, cb) ->
    opName = request.operation
    unless opName
        # No operation specified, reply immediately
        return cb?()

    opClass = OPERATIONS[opName]
    unless opClass
        logger.warn "Unimplemented operation #{opName}: #{inspect request}"
        return cb?(new errors.FeatureNotImplemented("Unimplemented operation #{opName}"))

    logger.debug "operations.run: #{inspect request}"
    op = new opClass(router, request)
    op.run (error, result) ->
        if error
            logger.warn "Operation #{opName} failed: #{error.stack or error}"
            cb? error
        else
            # Successfully done
            logger.debug "Operation #{opName} ran: #{inspect result}"
            try
                cb? null, result
            catch e
                logger.error e.stack or e

            # Run notifications
            notifications = []
            if (notification = op.notification?())
                for own node, notifications of groupByNode(notification)
                    notification.node = node
                    new Notify(router, notification).run (err) ->
                        if err
                            logger.error("Error running notifications: #{err.stack or err.message or err}")
            if (notification = op.moderatorNotification?())
                new ModeratorNotify(router, notification).run (err) ->
                    if err
                        logger.error("Error running notifications: #{err.stack or err.message or err}")


groupByNode = (updates) ->
    result = {}
    for update in updates
        unless result.hasOwnProperty(update.node)
            result[update.node] = []
        result[update.node].push update
    result
