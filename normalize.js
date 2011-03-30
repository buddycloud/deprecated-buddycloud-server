var NS_ATOM = 'http://www.w3.org/2005/Atom';

exports.normalizeItem = function(req, cb) {
    /* TODO: what if no ATOM? */
    normalizeEntry(Object.create(req, { entry: req.item,
					oldEntry: req.oldItem }), cb);
};

/**
 * Normalize an ATOM entry
 *
 * `req' is the controller request, annotated with the `item' and
 * `oldItem' fields.
 */
function normalizeEntry(req, cb) {
    try {
	normalizeAuthor(req);
	normalizeId(req);
	normalizePublished(req);
	normalizeUpdated(req);
	cb(null, req);
    } catch (e) {
	cb(e);
    }
};

function normalizeAuthor(req) {
    /* get user from request */
    var user, m;
    if ((m = req.from.match(/^.+?:(.+)$/)))
	user = m[1];
    else
	user = req.from;

    /* Delete <author/> children */
    req.entry.remove('author', NS_ATOM);
    /* <author>
     *   <uri>xmpp:foo@example.com</uri>
     *   <jid xmlns="...">foo@example.com</jid>
     * </author>
     */
    req.entry.c('author').
	c('uri').t(req.from).up().
	c('jid', { xmlns: "http://buddycloud.com/atom-elements-0" }).
	t(user);
}

function normalizeId(req) {
    req.item.remove('id', NS_ATOM);

    req.item.c('id').t(req.itemId);
}

function normalizePublished(req) {
    req.item.remove('published', NS_ATOM);

    var published = new Date().toISOString();
    /* Find previous published date */
    if (req.oldItem) {
	req.oldItem.getChildren('published').forEach(function(publishedEl) {
	    published = publishedEl.getText();
	});
    }
    req.item.c('published').t(published);
}

function normalizeUpdated(req) {
    req.item.remove('updated', NS_ATOM);

    var updated = new Date().toISOString();
    req.item.c('updated').t(updated);
}
