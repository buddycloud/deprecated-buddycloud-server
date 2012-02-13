nodeRegexp = /^\/user\/([^\/]+)\/?(.*)/
exports.getNodeUser = (node) ->
    unless node
        return null

    nodeRegexp.exec(node)?[1]

exports.getNodeType = (node) ->
    unless node
        return null

    nodeRegexp.exec(node)?[2]

exports.getUserDomain = (user) ->
    if user.indexOf('@') >= 0
        user.substr(user.indexOf('@') + 1)
    else
        user

exports.nodeTypes = [
    "posts", "status",
    "geo/previous", "geo/current", "geo/next",
    "subscriptions"
];
