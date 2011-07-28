NS = require('./ns')

class Notification
    constructor: (@opts) ->

    toStanza: (fromJid, toJid) ->
        new xmpp.Element('message',
            type: 'headline'
            from: fromJid
            to: toJid).
        c('event', xmlns: NS.PUBSUB_EVENT)


class PublishNotification
    toStanza: ->
        itemsEl = (super).
            c('items', node: @opts.node)
        @opts.items.forEach (item) ->
            itemsEl.c('item', id: item.id).
                cnode(item.el)
        itemsEl


NOTIFICATIONS =
    'publish-node-items': PublishNotification

