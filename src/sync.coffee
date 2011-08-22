async = require('async')

class Synchronization
    constructor: (@router, @node) ->
        @request = {
            operation: => @operation
            node: @node
            rsm: {}
        }

    run: (t, cb) ->
        console.log 'router.run': @request, cb: cb
        @router.run @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'retrieve-node-configuration'

    writeResults: (t, results, cb) ->
        t.setConfig @node, results, cb

##
# Walks items with RSM
class PaginatedSynchronization extends Synchronization
    run: (t, cb) ->
        # for detecting RSM loops
        seenOffsets = {}
        walk = (offset) =>
            @request.rsm.after ?= offset
            super t, (err, results) =>
                if err
                    return cb err

                go = (err) =>
                    if err
                        return cb err

                    @writeResults t, results, (err) ->
                    if err
                        return cb results

                    offset = results.rsm?.last
                    if offset
                        # Remote supports RSM, walk:
                        if seenOffsets.hasOwnProperty(offset)
                            cb new Error("RSM offset loop detected for #{@request.node}")
                        else
                            seenOffsets[offset] = true
                            walk offset
                    else
                        # No RSM support, done:
                        cb()

                # reset() only after 1st successful result
                unless @resetted  # (excuse my grammar)
                    # TODO: is async!
                    @resetted = true
                    @reset t, go
                else
                    go()
        # Go
        walk()

class ItemsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        # clear table

    operation: 'retrieve-node-items'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            # TODO: author?
            t.writeItem @node, item.id, null, item.el, cb2
        cb



exports.syncNode = (router, model, node, cb) ->
    async.forEachSeries [ConfigSynchronization, ItemsSynchronization]
    , (syncClass, cb2) ->
        synchronization = new syncClass(router, node)
        model.transaction (err, t) ->
            if err
                console.error err.stack or err
                return cb2 err

            synchronization.run (err) ->
                if err
                    console.error err.stack or err
                    t.rollback ->
                        cb2 err
                    return

                t.commit (err) ->
                    if err
                        return cb2 err

                    cb2()
    , cb
