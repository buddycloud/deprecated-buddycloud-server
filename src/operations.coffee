errors = require('./errors')

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (handler) ->
        @handler = handler

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
        # Check privileges


OPERATIONS =
    'browse-node-info': undefined

exports.run = (handler) ->
    opName = handler.operation()
    opClass = OPERATIONS[opName]

    unless opClass
        console.error "Unimplemented operation #{opName}"
        handler.replyError(new errors.NotImplemented("Unimplemented operation #{opName}"))
        return

    op = new opClass(handler)
    op.run (error, result) ->
        if error
            handler.replyError error
        else
            handler.reply result

