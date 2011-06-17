applyRSM = (rsmQuery, results) ->
  rsmQuery = rsmQuery or {}
  rsmResult = count: results.length
  if rsmQuery.after
    while results.length > 0
      key = results.shift()
      if key == rsmQuery.after
        break
  if rsmQuery.before
    while results.length > 0
      key = results.pop()
      if key == rsmQuery.before
        break
    if rsmQuery.count
      results = results.slice(Math.max(0, results.length - rsmQuery.count))
  if rsmQuery.count
    results = results.slice(0, rsmQuery.count)
  if results.length > 0
    rsmResult.first = results[0]
    rsmResult.last = results[results.length - 1]
  Object.create(rsmResult: rsmResult, o: results)
