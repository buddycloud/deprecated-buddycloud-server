xmpp = require('node-xmpp')
NS = require('./ns')

class exports.RSM
    ##
    # key = null: results is array of ids
    # key = String: results is array of objects, with key as id
    #
    # @return Modified results
    cropResults: (results, key) ->
        if key
            indexOf = (id) ->
                i = 0
                for result in results
                    if result[key] is id
                        return i
                    i++
                return -1
        else
            indexOf = (id) ->
                results.indexOf id

        # RSM offsets
        @firstIndex = 0
        @count = results.length
        if @after
            # Paging forward
            afterIdx = indexOf(@after)
            if afterIdx >= 0
                results = results.slice(afterIdx + 1)
                @firstIndex = afterIdx + 1
        if @before
            # Paging backwards
            beforeIdx = indexOf(@before)
            if beforeIdx >= 0
                results = results.slice(0, beforeIdx)
        # RSM crop item amount
        @max = Math.min(1000, @max or 1000)
        if 'before' of @
            # Paging backwards
            results = results.slice(Math.max(0, results.length - @max), results.length)
            @firstIndex = @count - results.length
        else
            # Paging forward
            results = results.slice(0, Math.min(@max, results.length))

        # And attach for convenience:
        results.rsm = @
        results

    setReplyInfo: (results, key) ->
        if @fromRemote
            # Do not change
            return

        delete @first
        delete @last
        if results.length > 0
            if key
                getKey = (result) -> result[key]
            else
                getKey = (result) -> result
            @first = getKey results[0]
            @last = getKey results[results.length - 1]

    rmRequestInfo: ->
        delete @max
        delete @after
        delete @before

    toXml: ->
        el = new xmpp.Element('set', xmlns: NS.RSM)

        ##
        # Request data
        if 'max' of @
            el.c('max').t("#{@max}")
        if 'index' of @
            el.c('index').t("#{@index}")
        if @after
            el.c('after').t(@after)
        if @before
            el.c('before').t(@before)

        ##
        # Response data
        if @first
            firstEl = el.c('first')
            firstEl.t(@first)
            if 'firstIndex' of @
                firstEl.attrs.index = "#{@firstIndex}"
        if @last
            el.c('last').t(@last)
        if 'count' of @
            el.c('count').t("#{@count}")

        el


exports.fromXml = (el, @fromRemote) ->
    rsm = new exports.RSM()
    unless el
        return rsm

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
