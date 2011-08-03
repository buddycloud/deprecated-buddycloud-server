NS = require('./ns')
forms = require('./forms')

##
# All notifications are per-node, so listeners can be fetched once
class Notification
    constructor: (@opts) ->

    toStanza: (fromJid, toJid) ->
        new xmpp.Element('message',
            type: 'headline'
            from: fromJid
            to: toJid
        ).c('event', xmlns: NS.PUBSUB_EVENT)


class PublishNotification extends Notification
    toStanza: ->
        itemsEl = (super).
            c('items', node: @opts.node)
        @opts.items.forEach (item) ->
            itemsEl.c('item', id: item.id).
                cnode(item.el)
        itemsEl

class SubscriptionsNotification extends Notification
    toStanza: ->
        subscriptionEl = (super).
            c('subscription')
        for {user, subscription} in @opts.subscriptions
            subscriptionEl.c('subscription',
                jid: user
                node: @opts.node
                subscription: subscription
            )
        subscriptionEl

class AffiliationsNotification extends Notification
    toStanza: ->
        affiliationEl = (super).
            c('affiliation')
        for {user, affiliation} in @opts.affiliations
            affiliationEl.c('affiliation',
                jid: user
                node: @opts.node
                affiliation: affiliation
            )
        affiliationEl

class ConfigNotification extends Notification
    toStanza: ->
        configurationEl = (super).
            c('configuration', node: @opts.node)

        form = new forms.Form('result', NS.PUBSUB_NODE_CONFIG)
        addField = (key, fvar, label) ->
            form.fields.push new forms.Field(fvar, 'text-single',
                label, @opts.config[key])
        addField 'title', 'pubsub#title',
            'A short name for the node'
        addField 'description', 'pubsub#description',
            'A description of the node'
        addField 'accessModel', 'pubsub#access_model',
            'Who may subscribe and retrieve items'
        addField 'publishModel', 'pubsub#publish_model',
            'Who may publish items'
        addField 'defaultAffiliation', 'pubsub#default_affiliation',
            'What role do new subscribers have?'
        configurationEl.cnode form.toXml()

        configurationEl

NOTIFICATIONS =
    'publish-node-items': PublishNotification
    'subscriptions-updated': SubscriptionsNotification
    'affiliations-updated': AffiliationsNotification
    'node-config-updated': ConfigNotification

exports.byEvent = (event) ->
    NOTIFICATIONS[event]
