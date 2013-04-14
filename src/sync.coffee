##
# Called by router to ensure per-node locking

logger = require('./logger').makeLogger 'sync'
async = require('async')
RSM = require('./xmpp/rsm')
NS = require('./xmpp/ns')
rsmWalk = require('./rsm_walk')
errors = require('./errors')

class Synchronization
    constructor: (@router, @node) ->
        @request = {
            operation: @operation
            node: @node
            writes: true
        }

    run: (t, cb) ->
        @runRequest (err, results) =>
            if err
                return cb err

            @reset t, (err) =>
                if err
                    return cb err

                @writeResults t, results, cb

    runRequest: (cb) ->
        @router.runRemotely @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'browse-node-info'

    reset: (t, cb) ->
        t.resetConfig(@node, cb)

    writeResults: (t, results, cb) ->
        if results.config
            t.setConfig(@node, results.config, cb)
        else
            cb(new Error("No pubsub meta data form found"))

##
# Walks items with RSM
class PaginatedSynchronization extends Synchronization
    constructor: ->
        super
        @request.rsm = new RSM.RSM()

    run: (t, cb) ->
        rsmWalk (offset, cb2) =>
            logger.debug "PaginatedSynchronization walk #{offset}"
            @request.rsm.after = offset
            @runRequest (err, results) =>
                logger.debug "ranRequest #{err or results?.length}"
                if err
                    return cb2 err

                go = (err) =>
                    if err
                        return cb2 err

                    @writeResults t, results, (err) =>
                        if err
                            return cb2 err

                        nextOffset = results.rsm?.last
                        cb2 null, nextOffset

                # reset() only after 1st successful result
                unless @resetted  # (excuse my grammar)
                    @resetted = true
                    @reset t, go
                else
                    go()
        , cb

class ItemsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetItems(@node, cb)

    operation: 'retrieve-node-items'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            t.writeItem @node, item.id, item.el, cb2
        , cb

class SubscriptionsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        # Preserve the subscriptions listeners that are local, which
        # is only a small subset of the global subscriptions to a
        # remote node.
        # Also preserve temporary subscriptions since they are not included in
        # the remote results.
        t.resetSubscriptions @node, (err, @userListeners) =>
            cb err

    operation: 'retrieve-node-subscriptions'

    run: (t, cb) ->
        super t, (err) =>
            if err
                return cb err

            cb2 = =>
                cb.apply @, arguments
            # After all subscriptions have synced, check if any local
            # subscriptions are left:
            t.getNodeLocalListeners @node, (err, listeners) =>
                if err
                    logger.error "Cannot get node listeners: #{err.stack or err}"

                if listeners? and listeners.length > 0
                    cb2()
                else
                    t.purgeRemoteNode @node, cb2

    # TODO: none left? remove whole node.
    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            listener = @userListeners[item.user]
            t.setSubscription @node, item.user, listener, item.subscription, false, cb2
        , cb

class AffiliationsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        async.waterfall [
            # Only AffiliationsSynchronization happens after
            # SubscriptionsSynchronization which may have purged the
            # node.
            t.validateNode @node
        , (cb2) =>
            t.resetAffiliations(@node, cb2)
        ], cb

    operation: 'retrieve-node-affiliations'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            t.setAffiliation @node, item.user, item.affiliation, cb2
        , cb


# TODO: move queueing here
syncQueue = async.queue (task, cb) ->
    { model, router, node, syncClass } = task
    synchronization = new syncClass(router, node)
    model.transaction (err, t) ->
        if err
            logger.error "sync transaction: #{err.stack or err}"
            return cb err

        synchronization.run t, (err) ->
            if err
                t.rollback ->
                    cb err
            else
                t.commit (err) ->
                    cb err
, 1

# TODO: emit notifications for all changed things?
exports.syncNode = (router, model, node, cb) ->
    logger.debug "syncNode #{node}"
    async.forEachSeries [
        ConfigSynchronization, ItemsSynchronization,
        SubscriptionsSynchronization, AffiliationsSynchronization
    ]
    , (syncClass, cb2) ->
        # For some reason syncClass is sometimes undefined...
        if syncClass?
            syncQueue.push { router, model, node, syncClass }, cb2
        else
            cb2()
    , (err) ->
        if err and err.constructor is errors.SeeLocal
            logger.debug "Omitted syncing local node #{node}"
            cb?()
        else if err
            logger.error "sync #{node}: #{err}"
            cb?(err)
        else
            logger.info "synced #{node}"
            cb?()

##
# Setup synchronization queue
exports.setup = (jobs) ->
    syncQueue.concurrency = jobs
