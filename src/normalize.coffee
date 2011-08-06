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
        normalizeAuthor req
        normalizeId req
        normalizePublished req
        normalizeUpdated req
        normalizeActivityStream req
        cb null, req
    catch e
        console.error e.stack
        cb e

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
    # The local now by default
    published = new Date().toISOString()
    # Find previous published date
    if req.oldItem?.el?
        req.oldItem.el.getChildren("published").forEach (publishedEl) ->
            published = publishedEl.getText()
    req.item.el.c("published").
        t(published)

normalizeUpdated = (req) ->
    req.item.el.remove "updated", NS_ATOM
    updated = new Date().toISOString()
    req.item.el.c("updated").
        t(updated)

normalizeActivityStream = (req) ->
    # Ensure a <activity:verb/>
    unless req.item.el.getChild('verb', NS_AS)
        verb = 'post'
        req.item.el.c('verb', xmlns: NS_AS).
            t(verb)
    # Ensure a <activity:object/>
    unless req.item.el.getChild('object', NS_AS)
        objectType = 'note'
        if req.item.el.getChild('in-reply-to', NS_THR)
            objectType = 'comment'
        req.item.el.c('object', xmlns: NS_AS).
            c('object-type').
            t(objectType)
