##
# Called by router to ensure per-node locking

logger = require('./logger').makeLogger 'sync'
async = require('async')
RSM = require('./xmpp/rsm')
NS = require('./xmpp/ns')
rsmWalk = require('./rsm_walk')

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
            logger.debug "PaginatedSynchronization walk %s", offset
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
                            return cb2 results

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
        t.resetSubscriptions @node, (err, @userListeners) =>
            cb err

    operation: 'retrieve-node-subscriptions'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            listener = @userListeners[item.user]
            t.setSubscription @node, item.user, listener, item.subscription, cb2
        , cb

class AffiliationsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetAffiliations(@node, cb)

    operation: 'retrieve-node-affiliations'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            t.setAffiliation @node, item.user, item.affiliations, cb2
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
                logger.error "sync run: #{err.stack or err}"
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
        syncQueue.push { router, model, node, syncClass }, cb2
    , (err) ->
        if err
            logger.error "sync #{node}: #{err}"
        else
            logger.info "synced #{node}"
        cb(err)

##
# Setup synchronization queue
exports.setup = (jobs) ->
    syncQueue.concurrency = jobs


nodeRegexp = /^\/user\/([^\/]+)\/?(.*)/
getNodeUser = (node) ->
    unless node
        return null

    m = nodeRegexp.exec(node)
    unless m
        return null

    m[1]
