async = require('async')
errors = require('../errors')

transaction = null
exports.setBackend = (backend) ->
    transaction = backend.transaction

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (request) ->
        @req = request

    run: (cb) ->
        cb new errors.NotImplemented("Operation defined but not yet implemented")

class ModelOperation extends Operation
    run: (cb) ->
        model.transaction (err, t) ->
            if err
                return req.callback err

            @transaction t, (err) ->
                if err
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        cb


    # Must be implemented by subclass
    transaction: (t, cb) ->
        cb null


class PrivilegedOperation extends Operation

    transaction: (t, cb) ->
        # TODO: Check privileges

        @privilegedTransaction t, cb


class BrowseInfo extends Operation

    run: (cb) ->
        console.log "BrowseInfo run"
        features = [
            NS.DISCO_ITEMS, NS.REGISTER,
            NS.PUBSUB, NS.PUBSUB_OWNER
        ]
        cb null,
            features: features
            identities: [
                category: "pubsub"
                type: "service"
                name: "Channels service",
                category: "pubsub"
                type: "channels"
                name: "Channels service"
            ]
        cb()

class Register extends ModelOperation
    # TODO: overwrite @run() and check if this component is
    # authoritative for the requesting user's domain
    transaction: (t, cb) ->
        user = @req.actor
        nodeTypes = [
                'channels', 'status',
                'geoloc/previous', 'geoloc/current',
                'geoloc/next', 'subscriptions']
        steps = nodeTypes.map (nodeType) =>
            (cb2) =>
                node = "/user/#{user}/#{nodeType}"
                t.createNode node, cb2
        steps.push cb
        async.series steps

class Publish extends PrivilegedOperation
    requiredAffiliation: 'publisher'

    privilegedTransaction: (t, cb) ->
        steps = @req.items.map (item) =>
            (cb2) =>
                t.writeItem @req.actor, @req.node, item.id, item.els[0].toString(), cb2
        steps.push cb
        async.series steps



OPERATIONS =
    'browse-node-info': undefined
    'browse-info': BrowseInfo
    'register-user': Register
    'publish-node-items': Publish

exports.run = (request) ->
    unless opName
        # No operation specified, reply immediately
        request.reply()
        return

    opName = request.operation()
    opClass = OPERATIONS[opName]

    unless opClass
        console.error "Unimplemented operation #{opName}"
        console.log request: request
        request.replyError(new errors.FeatureNotImplemented("Unimplemented operation #{opName}"))
        return

    console.log "Creating operation #{opName}"
    op = new opClass(request)
    op.run (error, result) ->
        if error
            request.replyError error
        else
            request.reply result

