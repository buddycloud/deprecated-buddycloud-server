NS = require('./ns')
forms = require('./forms')

##
# All notifications are per-node, so listeners can be fetched once
class exports.Notification
    constructor: (@opts) ->

    toStanza: (fromJid, toJid) ->
        eventEl = new xmpp.Element('message',
                type: 'headline'
                from: fromJid
                to: toJid
            ).c('event', xmlns: NS.PUBSUB_EVENT)
        for update in @opts
            switch update.type
                when 'items'
                    itemsEl = eventEl.
                        c('items', node: update.node)
                    for item in update.items
                        itemsEl.c('item', id: item.id).
                            cnode(item.el)
                when 'subscription'
                    eventEl.
                        c('subscription',
                            jid: update.user
                            node: update.node
                            subscription: update.subscription
                        )
                when 'affiliation'
                    eventEl.
                        c('affiliation',
                            jid: update.user
                            node: update.node
                            affiliation: update.affiliation
                        )
                when 'config'
                    eventEl.
                        c('configuration',
                            node: update.node
                        ).cnode(forms.formToResultForm(update.config, NS.PUBSUB_NODE_CONFIG).toXml())
        eventEl.up()
