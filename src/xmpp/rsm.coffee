xmpp = require('node-xmpp')
NS = require('./ns')

exports.fromXml = (el) ->
    rsm = {}

    ##
    # Request data
    if (max = el.getChildText('max'))
        rsm.max = parseInt(max, 10)
    if (index = el.getChildText('index'))
        rsm.index = parseInt(index, 10)
    # Creates key even if <after/> empty
    if (afterEl = el.getChild('after'))?
        rsm.after = afterEl.getText()
    if (beforeEl = el.getChild('before'))?
        rsm.before = beforeEl.getText()

    ##
    # Response data
    if (firstEl = el.getChild('first'))
        rsm.first = firstEl.getText()
        if 'index' of firstEl.attrs
            rsm.firstIndex = parseInt(firstEl.attrs.index, 10)
    rsm.last ?= el.getChildText('last')
    if (count = el.getChild('count')?.getText())
        rsm.count = parseInt(count, 10)

    rsm


exports.toXml = (rsm) ->
    el = new xmpp.Element('set', xmlns: NS.RSM)

    ##
    # Request data
    if 'max' of rsm
        el.c('max').t("#{rsm.max}")
    if 'index' of rsm
        el.c('index').t("#{rsm.index}")
    if 'after' of rsm
        el.c('after').t(rsm.after)
    if 'before' of rsm
        el.c('before').t(rsm.before)

    ##
    # Response data
    if 'first' of rsm or 'firstIndex' of rsm
        firstEl = el.c('first')
        if 'first' of rsm
            firstEl.t(rsm.first)
        if 'firstIndex' of rsm
            firstEl.attrs.index = "#{rsm.firstIndex}"
    if 'last' of rsm
        el.c('last').t(rsm.last)
    if 'count' of rsm
        el.c('count').t("#{rsm.count}")

    el

