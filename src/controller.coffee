class UserContent
    constructor: (id) ->
        @id = Id
        @operationsQueue = []
        @frontend = null

    findFrontend: () ->

##
# Is created with options from the request
#
# Implementations set result
class Operation
    constructor: (opts) ->
        @opts = opts

    run: (cb) ->
        model.transaction (err, t) ->
            if err
                return req.callback err

            @transaction t, (err) ->
                if err
                    t.rollback ->
                        cb err
                else
                    t.commit ->
                        cb

    transaction: (t, cb) ->
        # Must be implemented by subclass
        cb null

class PrivilegedOperation extends Operation

    transaction: (t, cb) ->
        # Check privileges

defaultConfig = (req) ->
  owner = req.from
  a = owner.split(":")
  owner = a[a.length - 1].split("@")[0]

    title: owner + "'s node"
    description: "Where " + owner + " publishes things"
    type: "http://www.w3.org/2005/Atom"
    accessModel: "open"
    publishModel: "subscribers"
    creationDate: new Date().toISOString()
isAffiliationSubset = (subset, affiliation) ->
  subset == affiliation or (AFFILIATION_SUBSETS.hasOwnProperty(affiliation) and AFFILIATION_SUBSETS[affiliation].indexOf(subset) >= 0)
callFrontend = (hook, uri) ->
  colonPos = uri.indexOf(":")
  if colonPos > 0
    proto = uri.substr(0, colonPos)
    uri = uri.substr(colonPos + 1)
  else
    return
  args = Array::.slice.call(arguments, 1)
  frontend = frontends.hasOwnProperty(proto) and frontends[proto]
  hookFun = frontend and frontend.hasOwnProperty(hook) and frontend[hook]
  console.log
    callFrontend: arguments
    frontent: frontend
    hookFun: hookFun
    args: args

  if hookFun
    return hookFun.apply(frontend, args)
objectIsEmpty = (o) ->
  for k of o
    if o.hasOwnProperty(k)
      return false
  true
step = require("step")
errors = require("./errors")
normalize = require("./normalize")

exports.setModel = (m) ->
  model = m

FEATURES =
  "create-nodes": create:
    requiredAffiliation: "owner"
    transaction: (req, t, cb) ->
      step ->
        t.createNode req.node, this
      , (err) ->
        if err
          throw err
        t.setConfig req.node, defaultConfig(req), this
      , (err) ->
        if err
          throw err
        t.setAffiliation req.node, req.from, "owner", this
      , (err) ->
        if err
          throw err
        t.setSubscription req.node, req.from, "subscribed", this
      , cb

  subscribe:
    subscribe:
      transaction: (req, t, cb) ->
        step ->
          t.getConfig req.node, this
        , (err, config_) ->
          if err
            throw err
          config = config_
          if not config.accessModel or config.accessModel == "open"
            this null, "subscribed"
          else
            t.getSubscription req.node, req.from, this
        , (err, subscription) ->
          if err
            throw err
          unless subscription
            switch config.accessModel
              when "authorize"
                this null, "pending"
              else
                throw new errors.Forbidden()
          else
            this null, subscription
        , (err, subscription) ->
          if err
            throw err
          req.subscription = subscription
          t.setSubscription req.node, req.from, subscription, this
        , (err) ->
          if err
            throw err
          if req.subscription == "pending"
            step ->
              t.getOwners req.node, this
            , (err, owners) ->
              if err
                throw err
              req.owners = owners
              this null, req.subscription
            , this
          else
            this null, req.subscription
        , cb

      afterTransaction: (req) ->
        if req.subscription == "pending" and req.owners
          req.owners.forEach (owner) ->
            callFrontend "approve", owner, req.node, req.from

    unsubscribe: transaction: (req, t, cb) ->
      nodeM = req.node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/\-]+)$/)
      userM = req.from.match(/^(.+?):(.+)$/)
      if nodeM and nodeM[1] == userM[2]
        cb new errors.NotAllowed("Owners must not abandon their channels")
        return
      t.setSubscription req.node, req.from, "none", cb

  publish: publish:
    requiredAffiliation: "publisher"
    transaction: (req, t, cb) ->
      step ->
        if objectIsEmpty(req.items)
          this null, []
        else
          g = @group()
          for id of req.items
            if req.items.hasOwnProperty(id)
              step ->
                t.getItem req.node, id, this
              , (err, oldItem) ->
                reqItem = Object.create(req)
                reqItem.item = req.items[id]
                reqItem.itemId = id
                reqItem.oldItem = oldItem
                normalize.normalizeItem reqItem, this
              , (err, reqNormalized) ->
                if err
                  throw err
                t.writeItem req.from, req.node, reqNormalized.itemId, reqNormalized.item, this
              , g()
      , cb

    subscriberNotification: (req, subscribers) ->
      subscribers.forEach (subscriber) ->
        callFrontend "notify", subscriber.user, req.node, req.items

  "retract-items": retract:
    requiredAffiliation: "publisher"
    transaction: (req, t, cb) ->
      step ->
        if req.itemIds.length < 1
          this null, []
        else
          g = @group()
          req.itemIds.forEach (itemId) ->
            t.deleteItem req.node, itemId, g()
      , cb

    subscriberNotification: (req, subscribers) ->
      subscribers.forEach (subscriber) ->
        callFrontend "retracted", subscriber.user, req.node, req.itemIds

  "retrieve-items":
    retrieve:
      requiredAffiliation: "member"
      transaction: (req, t, cb) ->
        step ->
          t.getItemIds req.node, this
        , (err, ids_) ->
          if err
            throw err
          ids = applyRSM(req.rsmQuery, ids_)
          if ids.length < 1
            this null, []
          else
            g = @group()
            ids.forEach (id) ->
              t.getItem req.node, id, g()
        , (err, items) ->
          if err
            throw err
          results = []

          while (id = ids.shift()) and (item = items.shift())
            results.push
              id: id
              item: item
          results.rsmResult = ids.rsmResult
          this null, results
        , cb

    replay: transaction: (req, t, cb) ->
      t.getUpdatesByTime req.from, req.timeStart, req.timeEnd, req.notifyCb, cb

  "retrieve-subscriptions": retrieve: transaction: (req, t, cb) ->
    t.getSubscriptions req.from, cb

  "retrieve-affiliations": retrieve: transaction: (req, t, cb) ->
    t.getAffiliations req.from, cb

  "manage-subscriptions":
    retrieve:
      requiredAffiliation: "member"
      transaction: (req, t, cb) ->
        t.getSubscribers req.node, cb

    modify:
      requiredAffiliation: "owner"
      transaction: (req, t, cb) ->
        step ->
          if objectIsEmpty(req.subscriptions)
            this null
            return
          g = @group()
          for user of req.subscriptions
            subscription = req.subscriptions[user]
            switch subscription
              when "subscribed"
                t.setSubscription req.node, user, g()
              when "none"
                t.setSubscription req.node, user, g()
              else
                throw new errors.BadRequest(subscription + " is no subscription type")
        , cb

      afterTransaction: (req) ->
        for user of req.subscriptions
          callFrontend "subscriptionModified", user, req.subscriptions[user]

  "modify-affiliations":
    retrieve:
      requiredAffiliation: "member"
      transaction: (req, t, cb) ->
        t.getAffiliated req.node, cb

    modify:
      requiredAffiliation: "owner"
      transaction: (req, t, cb) ->
        if objectIsEmpty(req.affiliations)
          this null
          return
        step ->
          g = @group()
          for user of req.affiliations
            affiliation = req.affiliations[user]
            t.setAffiliation req.node, user, affiliation, g()
        , cb

  "config-node":
    retrieve:
      requiredAffiliation: "member"
      transaction: (req, t, cb) ->
        step ->
          t.getConfig req.node, this
        , (err, config) ->
          unless config
            config = defaultConfig(req)
          this null, config
        , cb

    modify:
      requiredAffiliation: "owner"
      transaction: (req, t, cb) ->
        step ->
          t.getConfig req.node, this
        , (err, config) ->
          unless config
            config = defaultConfig(req)
          req.config = config
          t.setConfig req.node,
            title: req.title or config.title
            description: req.description or config.description
            type: req.type or config.type
            accessModel: req.accessModel or config.accessModel
            publishModel: req.publishModel or config.publishModel
            creationDate: config.creationDate
          , this
        , cb

      subscriberNotification: (req, subscribers) ->
        subscribers.forEach (subscriber) ->
          callFrontend "configured", subscriber.user, req.node, req.config

  "get-pending":
    "list-nodes": transaction: (req, t, cb) ->
      t.getPendingNodes req.from, cb

    "get-for-node":
      requiredAffiliation: "owner"
      transaction: (req, t, cb) ->
        step ->
          t.getPending req.node, this
        , (err, users) ->
          if err
            throw err
          req.pendingUsers = users
          this null
        , cb

      afterTransaction: (req) ->
        req.pendingUsers.forEach (user) ->
          callFrontend "approve", req.from, req.node, user

  register: register: transaction: (req, t, cb) ->
    user = req.from
    if (m = user.match(/^.+:(.+)$/))
      user = m[1]
    nodes = [ "channel", "mood", "subscriptions", "geo/current", "geo/future", "geo/previous" ].map((name) ->
      "/user/" + user + "/" + name
    )
    step ->
      g = @group()
      nodes.forEach (node) ->
        t.createNode node, g()
    , (err) ->
      if err
        throw err
      g = @group()
      nodes.forEach (node) ->
        t.setConfig node, defaultConfig(req), g()
        t.setAffiliation node, req.from, "owner", g()
        t.setSubscription node, req.from, "subscribed", g()
    , cb

  "browse-nodes":
    list: transaction: (req, t, cb) ->
      t.listNodes cb

    "by-user": transaction: (req, t, cb) ->
      if (m = req.node.match(/^\/user\/([^\/]+)$/))
        t.listNodesByUser m[1], cb
      else
        throw new errors.NotFound("User not found")

exports.pubsubFeatures = ->
  result = []
  for f of FEATURES
    result.push f
  result

exports.request = (req) ->
  feature = FEATURES[req.feature]
  operation = feature and feature[req.operation]
  req.affiliation = "none"
  unless operation
    req.callback new errors.FeatureNotImplemented("Operation not yet supported")
    return
  debug = (s) ->
    console.log req.from + " >> " + req.feature + "/" + req.operation + ": " + s

  if req.node and req.from
    nodeM = req.node.match(/^\/user\/(.+?)\/([a-zA-Z0-9\/\-]+)$/)
    userM = req.from.match(/^(.+?):(.+)$/)
    if nodeM and nodeM[1] == userM[2]
      req.affiliation = "owner"
  model.transaction (err, t) ->
    if err
      req.callback err
      return
    steps = [ (err) ->
      this null
     ]
    if operation.requiredAffiliation and not isAffiliationSubset(operation.requiredAffiliation, req.affiliation)
      steps.push (err) ->
        if err
          throw err
        t.getConfig req.node, this
      , (err, config_) ->
        if err
          throw err
        config = config_
        t.getAffiliation req.node, req.from, this
      , (err, affiliation) ->
        if err
          throw err
        req.affiliation = affiliation or req.affiliation
        t.getSubscription req.node, req.from, this
      , (err, subscription) ->
        if err
          throw err
        if req.affiliation == "none" and (not config.accessModel or config.accessModel == "open")
          req.affiliation = "member"
        else if req.affiliation == "member" and config.publishModel == "publishers" and subscription == "subscribed"
          req.affiliation = "publisher"
        if isAffiliationSubset(operation.requiredAffiliation, req.affiliation)
          this()
        else
          this new errors.Forbidden(operation.requiredAffiliation + " required")

    steps.push (err) ->
      if err
        throw err
      debug "transaction"
      operation.transaction req, t, this
    , (err) ->
      if err
        throw err
      debug "transaction done"
      transactionResults = arguments
      this null


    if operation.subscriberNotification
      steps.push (err) ->
        if err
          throw err
        t.getSubscribers req.node, this
      , (err, subscribers_) ->
        if err
          throw err
        subscribers = subscribers_
        this null
    steps.push (err) ->
      if err
        that = this
        debug "transaction rollback: " + (err.message or JSON.stringify(err))
        t.rollback ->
          that err
      else
        debug "transaction commit"
        t.commit this

    if operation.afterTransaction
      steps.push (err) ->
        if err
          throw err
        operation.afterTransaction req
        this null
    if operation.subscriberNotification
      steps.push (err) ->
        if err
          throw err
        operation.subscriberNotification req, subscribers
        this null
    steps.push (err) ->
      debug "callback"
      if err and req.callback
        unless err.stack
          err.stack = (err.message or err.condition or "Error") + " @ " + req.feature + "/" + req.operation
        req.callback err
      else if req.callback
        req.callback.apply req, transactionResults

    step.apply null, steps

exports.getAllSubscribers = (cb) ->
  model.transaction (err, t) ->
    if err
      cb err
      return
    t.getAllSubscribers (err, subscribers) ->
      if err
        t.rollback ->
          cb err

        return
      t.commit ->
        cb null, subscribers

AFFILIATION_SUBSETS =
  owner: [ "moderator", "publisher", "member", "none" ]
  moderator: [ "publisher", "member", "none" ]
  publisher: [ "member", "none" ]
  member: [ "none" ]

frontends = {}
exports.hookFrontend = (proto, hooks) ->
  frontends[proto] = hooks
