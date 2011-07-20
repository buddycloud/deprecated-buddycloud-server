async = require('async')
errors = require('../errors')
ltx = require("ltx")

runTransaction = null
exports.setBackend = (backend) ->
    runTransaction = backend.transaction


parseItem = (xml) ->
    try
        return ltx.parse(xml)
    catch e
        console.error "Parsing " + xml + ": " + e.stack
        return undefined

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (request) ->
        @req = request

    run: (cb) ->
        cb new errorsFeature.NotImplemented("Operation defined but not yet implemented")

class ModelOperation extends Operation
    run: (cb) ->
        runTransaction (err, t) =>
            if err
                return cb err

            @transaction t, (err) ->
                if err
                    console.error "Transaction rollback: #{err}"
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        console.log "committed"
                        cb null


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
        nodeTypes = [
                'channel', 'status',
                'geoloc/previous', 'geoloc/current',
                'geoloc/next', 'subscriptions']
        async.series(nodeTypes.map((nodeType) ->
            (cb2) ->
                node = "/user/#{user}/#{nodeType}"
                console.log "creating #{node}"
                t.createNode node, cb2
        ), cb)

class Publish extends PrivilegedOperation
    requiredAffiliation: 'publisher'

    privilegedTransaction: (t, cb) ->
        async.series(@req.items.map((item) =>
            (cb2) =>
                t.writeItem @req.actor, @req.node, item.id, item.els[0].toString(), cb2
        ), cb)

class Subscribe extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.setSubscription @req.node, @req.actor, 'subscribed', cb

##
# Not privileged as anybody should be able to unsubscribe him/herself
class Unsubscribe extends ModelOperation
    transaction: (t, cb) ->
        t.setSubscription @req.node, @req.actor, 'none', cb


class RetrieveItems extends PrivilegedOperation
    requiredAffiliation: 'member'

    privilegedTransaction: (t, cb) ->
        t.getItemIds @req.node, (err, ids) =>
            # TODO: apply RSM to ids
            results = []
            async.series ids.map((id) =>
                (cb2) =>
                    t.getItem @req.node, id, (err, xml) =>
                        if err
                            return cb2 err

                        try
                            item = parseItem(xml)
                            @req.results.push
                                id: id
                                els: [item]
                        catch e
                            cb2 e
            ), (err) ->
                if err
                    cb err
                else
                    cb null, results


OPERATIONS =
    'browse-node-info': undefined
    'browse-info': BrowseInfo
    'register-user': Register
    'publish-node-items': Publish
    'subscribe-node': Subscribe
    'unsubscribe-node': Unsubscribe
    'retrieve-node-items': RetrieveItems

exports.run = (request) ->
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
    op = new opClass(request)
    op.run (error, result) ->
        console.log "operation ran: #{error}, #{result}"
        if error
            request.replyError error
        else
            request.reply result

