nodeRegexp = /^\/user\/([^\/]+)\/?(.*)/
exports.getNodeUser = (node) ->
    unless node
        return null

    m = nodeRegexp.exec(node)
    unless m
        return null

    m[1]


exports.getUserDomain = (user) ->
    if user.indexOf('@') >= 0
        user.substr(user.indexOf('@') + 1)
    else
        user
