logger = require('./logger').makeLogger 'normalize'
{ JID } = require('node-xmpp')
moment = require('moment')
errors = require('./errors')

NS_ATOM = "http://www.w3.org/2005/Atom"
NS_AS = "http://activitystrea.ms/spec/1.0/"
NS_THR = "http://purl.org/syndication/thread/1.0"

nodeRegexp = /^\/user\/([^\/]+)\/(.+)/

exports.normalizeItem = (req, oldItem, item, cb) ->
    unless (m = nodeRegexp.exec(req.node))
        return cb new errors.BadRequest("No recognized node type")

    nodeType = m[2]
    # TODO: apply according to pubsub#type config
    if nodeType is 'posts' or
       nodeType is 'status'
        if item.el?.is('entry', NS_ATOM)
            req2 = Object.create(req)
            req2.nodeType = nodeType
            req2.oldItem = oldItem
            req2.item = item
            normalizeEntry req2, (err, req3) ->
                cb err, req3?.item
        else
            cb new errors.BadRequest("Item payload must be an ATOM entry")
    else
        # Other nodeType, no ATOM to enforce
        cb null, item

##
# Normalize an ATOM entry
#
# `req' is the controller request, annotated with the `item' and
# `oldItem' fields.
normalizeEntry = (req, cb) ->
    try
        normalizeTextNodes req
        normalizeAuthor req
        normalizeId req
        normalizePublished req
        normalizeUpdated req
        normalizeLink req
        normalizeActivityStream req
        cb null, req
    catch e
        logger.error e.stack
        cb e

# Remove empty text nodes (<entry> <child/> </entry> -->
# <entry><child/><entry>), except in content item (may contain HTML or other markup).
normalizeTextNodes = (req) ->
    deleteEmptyTextNodes = (el) ->
        unless el.is('content', NS_ATOM)
            cleanChildren = []
            for child in el.children
                if typeof child is 'string'
                    unless child.trim().length is 0
                        cleanChildren.push child
                else
                    cleanChildren.push deleteEmptyTextNodes(child)
            el.children = cleanChildren
        return el
    req.item.el = deleteEmptyTextNodes req.item.el

# <author>
#   <uri>acct:foo@example.com</uri>
# </author>
normalizeAuthor = (req) ->
    # Deal with an arbitrary amount of <author/> elements, ensuring at
    # least one
    authorEls = req.item.el.getChildren('author')
    if authorEls.length < 1
        authorEls = [req.item.el.c('author')]
    authorEls.forEach (authorEl) ->
        authorEl.remove 'uri'
        authorEl.c('uri').
            t("acct:#{req.actor}")

normalizeId = (req) ->
    req.item.el.remove "id", NS_ATOM
    req.item.el.c("id").t req.item.id

normalizePublished = (req) ->
    req.item.el.remove "published", NS_ATOM
    published = moment.utc().format()
    # Find previous published date
    if req.oldItem?
        req.oldItem.getChildren("published").forEach (publishedEl) ->
            published = publishedEl.getText()
    req.item.el.c("published").
        t(published)

normalizeUpdated = (req) ->
    req.item.el.remove "updated", NS_ATOM
    updated = moment.utc().format()
    req.item.el.c("updated").
        t(updated)

normalizeActivityStream = (req) ->
    irtEl = req.item.el.getChild('in-reply-to', NS_THR)
    # Ensure a <activity:verb/>
    unless req.item.el.getChild('verb', NS_AS)
        verb = if irtEl then 'comment' else 'post'
        req.item.el.c('verb', xmlns: NS_AS).
            t(verb)
    # Ensure a <activity:object/>
    unless req.item.el.getChild('object', NS_AS)
        objectType = if irtEl then 'comment' else 'note'
        req.item.el.c('object', xmlns: NS_AS).
            c('object-type').
            t(objectType)

normalizeLink = (req) ->
    link = "xmpp:#{req.me}?pubsub;action=retrieve;" +
        "node=#{encodeURI req.node};" +
        "item=#{encodeURI req.item.id}"
    alreadyPresent = req.item.el.children.some (child) ->
        typeof child != 'string' and
        child.is('link') and
        child.attrs.rel is 'self' and
        child.attrs.href is link
    unless alreadyPresent
        req.item.el.c('link',
            rel: 'self'
            href: link
        )

##
# Check if an Atom is valid. A valid Atom must have an author URI and non-empty
# <content/>, <id/>, <published/> and <updated/> elements.
exports.validateItem = (el) ->
    return false unless el? and el.is('entry', NS_ATOM)

    authorUri = el.getChild('author')?.getChild('uri')
    return false unless authorUri?
    m = /^acct\:(.+)/.exec authorUri.getText()
    return false unless m? and m[1]? and new JID(m[1]).bare().toString() is m[1]

    for name in ['content', 'id', 'published', 'updated']
        nameEl = el.getChild(name, NS_ATOM)
        return false unless nameEl?.getText().length > 0

    for name in ['published', 'updated']
        nameEl = el.getChild(name, NS_ATOM)
        txt = nameEl?.getText()
        return false unless txt?.length > 0 and moment(txt).isValid()

    return true
