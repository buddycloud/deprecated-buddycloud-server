CommonLogger = require 'common-logger'
fs = require 'fs'

config = {}
logFile = undefined
exports.setConfig = (config_) ->
    config = config_
    if config_.file
        logFile = fs.createWriteStream config_.file

class Logger extends CommonLogger
    constructor: (@module) ->
        # Translate user-passed string to level index
        config.level = CommonLogger.levels.indexOf config.level
        super(config)

    # + @module output
    format: (date, level, message) ->
        "[#{date.toUTCString()}] #{@constructor.levels[level]} [#{@module}] #{message}"

    # more targets than just console.log()
    out: (message) ->
        if config.stdout
            console.log message
        if logFile
            logFile.write "#{message}\n"

exports.makeLogger = (module) ->
    new Logger(module)
