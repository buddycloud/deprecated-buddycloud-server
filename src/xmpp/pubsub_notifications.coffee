xmpp = require('node-xmpp')
NS = require('./ns')
forms = require('./forms')

##
# All notifications are per-node, so listeners can be fetched once
#
# TODO: enforce MAX_STANZA_LIMIT
class Notification
    constructor: (@opts) ->

    toStanza: (fromJid, toJid) ->
        message = new xmpp.Element('message',
                type: 'headline'
                from: fromJid
                to: toJid
            )

        if @opts.replay
            # For the MAM case the stanza is packaged up into
            # <forwarded/>
            message.c('forwarded', xmlns: NS.FORWARD).
                c('message',
                        type: 'headline'
                        from: fromJid
                        to: toJid
                    )
        else
            message

class EventNotification extends Notification
    toStanza: (fromJid, toJid) ->
        eventEl = super.c('event', xmlns: NS.PUBSUB_EVENT)
        for update in @opts
            switch update.type
                when 'items'
                    itemsEl = eventEl.
                        c('items', node: update.node)
                    if update.items? then for item in update.items
                        itemsEl.c('item', id: item.id).
                            cnode(item.el)
                    if update.retract? then for item in update.retract
                        itemsEl.c('retract', id: item.id)
                        itemsEl.c('item', id: item.id).
                            cnode(item.el)
                when 'subscription'
                    eventEl.
                        c('subscription',
                            jid: update.user
                            node: update.node
                            subscription: update.subscription
                            temporary: if update.temporary then '1' else '0'
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
                        ).cnode(forms.configToForm(update.config, 'result', NS.PUBSUB_NODE_CONFIG).toXml())
        eventEl

##
# <message to='hamlet@denmark.lit' from='pubsub.shakespeare.lit' id='approve1'>
#   <x xmlns='jabber:x:data' type='form'>
#     <title>PubSub subscriber request</title>
#     <instructions>
#       To approve this entity&apos;s subscription request,
#       click the OK button. To deny the request, click the
#       cancel button.
#     </instructions>
#     <field var='FORM_TYPE' type='hidden'>
#       <value>http://jabber.org/protocol/pubsub#subscribe_authorization</value>
#     </field>
#     <field var='pubsub#subid' type='hidden'><value>123-abc</value></field>
#     <field var='pubsub#node' type='text-single' label='Node ID'>
#       <value>princely_musings</value>
#     </field>
#     <field var='pusub#subscriber_jid' type='jid-single' label='Subscriber Address'# >
#       <value>horatio@denmark.lit</value>
#     </field>
#     <field var='pubsub#allow' type='boolean'
#            label='Allow this JID to subscribe to this pubsub node?'>
#       <value>false</value>
#     </field>
#   </x>
# </message>
class AuthorizationPromptNotification extends Notification
    toStanza: (fromJid, toJid) ->
        form = new forms.Form('form', NS.PUBSUB_SUBSCRIBE_AUTHORIZATION)
        form.title = 'Confirm channel subscription'
        form.instructions = "Allow #{@opts.user} to subscribe to node #{@opts.node}?"
        form.addField 'pubsub#node', 'text-single',
            'Node', @opts.node
        form.addField 'pubsub#subscriber_jid', 'jid-single',
            'Subscriber Address', @opts.user
        form.addField 'pubsub#allow', 'boolean',
            'Allow?', 'false'

        super.cnode form.toXml()

exports.make = (opts) ->
    switch opts.type
        when 'authorizationPrompt'
            new AuthorizationPromptNotification(opts)
        else
            new EventNotification(opts)
