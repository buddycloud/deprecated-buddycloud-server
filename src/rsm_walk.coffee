##
# @param iter(nextOffset, cb(err, lastOffset))
# @param cb(err)
module.exports = (iter, cb) ->
    # for detecting RSM loops
    seenOffsets = {}
    walk = (offset) ->
        iter offset, (err, lastOffset) ->
            if err
                return cb err

            if lastOffset
                # Remote supports RSM, walk:
                if seenOffsets.hasOwnProperty(lastOffset)
                    cb new Error("RSM offset loop detected for #{@request.node}: #{offset} already seen")
                else
                    seenOffsets[lastOffset] = true
                    walk lastOffset
            else
                # No RSM support, done:
                cb()

    # Go
    walk()
