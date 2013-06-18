logger = require('./logger').makeLogger 'tombstone'
{Element} = require('node-xmpp')
moment = require('moment')

NS_AS = "http://activitystrea.ms/spec/1.0/"
NS_AT = "http://purl.org/atompub/tombstones/1.0"
NS_ATOM = "http://www.w3.org/2005/Atom"
NS_THR = "http://purl.org/syndication/thread/1.0"

exports.makeTombstone = (item) ->
    ref = item.getChild('link', NS_ATOM).attrs.href
    now = moment.utc().format()
    tsEl = new Element('deleted-entry', xmlns: NS_AT, ref: ref, when: now).
        c("updated", xmlns: NS_ATOM).t(now).up()

    children = []
    children.push(item.getChild(name, NS_ATOM)?.attr('xmlns', NS_ATOM)) for name in ['id', 'link', 'published']
    children.push(item.getChild('in-reply-to', NS_THR)?.attr('xmlns', NS_THR))
    children.push(item.getChild(name, NS_AS)?.attr('xmlns', NS_AS)) for name in ['object', 'verb']
    for child in children
        tsEl = tsEl.cnode(child).up() if child?

    return tsEl
