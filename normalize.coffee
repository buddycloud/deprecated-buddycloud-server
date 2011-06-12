NS_ATOM = "http://www.w3.org/2005/Atom"

exports.normalizeItem = (req, cb) ->
    # TODO: what if no ATOM?
    reqNormalize = Object.create(req)
    reqNormalize.entry = req.item
    reqNormalize.oldEntry = req.oldItem
    normalizeEntry reqNormalize, cb

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
        cb null, req
    catch e
        cb e

normalizeAuthor = (req) ->
    # get user from request
    if (m = req.from.match(/^.+?:(.+)$/))
        user = m[1]
    else
        user = req.from

    # Delete <author/> children
    req.entry.remove "author", NS_ATOM
    # <author>
    #   <uri>xmpp:foo@example.com</uri>
    #   <jid xmlns="...">foo@example.com</jid>
    # </author>
    req.entry.c("author").c("uri").t(req.from).up().c("jid", xmlns: "http://buddycloud.com/atom-elements-0").t user

normalizeId = (req) ->
    req.item.remove "id", NS_ATOM
    req.item.c("id").t req.itemId

normalizePublished = (req) ->
    req.item.remove "published", NS_ATOM
    published = new Date().toISOString()
    # Find previous published date
    if req.oldItem
        req.oldItem.getChildren("published").forEach (publishedEl) ->
            published = publishedEl.getText()
    req.item.c("published").t published

normalizeUpdated = (req) ->
    req.item.remove "updated", NS_ATOM
    updated = new Date().toISOString()
    req.item.c("updated").t updated
