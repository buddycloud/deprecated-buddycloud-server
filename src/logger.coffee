nlogger = require 'cnlogger'

exports.makeLogger = (filename) ->
    nlogger.logger(filename)
