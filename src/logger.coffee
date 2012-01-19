{ constructor: CommonLogger } = require 'underscore.logger'
SysLogger = require 'ain2'
fs = require 'fs'

config = {}
logFile = undefined
exports.setConfig = (config_) ->
    config = Object.create(config_)
    # Translate user-passed string to level index
    config.level = Math.max(0, CommonLogger.levels.indexOf config_.level)

    if config_.file
        logFile = fs.createWriteStream config_.file, flags: 'a'
    # syslog needs a hostname as dgram_unix
    # support has been removed from node.
    if config_.syslog? and Object.keys(config_.syslog).length > 0
        ain2 = new SysLogger()
        ain2.set
            tag: 'buddycloud'
            facility: 'daemon'
            transport: 'file'
        if config_.syslog.hostname
            ain2.set
                transport: 'udp'
                hostname: config_.syslog.hostname
        if config_.syslog.port
            ain2.set port: config_.syslog.port

class Logger extends CommonLogger
    constructor: (@module) ->
        super(config)

    # Monkey patch to always convert the format string object to an actual string
    _log: (level, args) ->
        if args[0] and typeof args[0] isnt 'string'
            args[0] = args[0].toString()
        super

    # + @module output
    format: (date, level, message) ->
        "[#{date.toUTCString()}] #{CommonLogger.levels[level]} [#{@module}] #{message}"

    # more targets than just console.log()
    out: (message) ->
        if config.stdout
            console.log message
        if logFile
            logFile.write "#{message}\n"
        if config.syslog? and Object.keys(config.syslog).length > 0
            ain2?['info']?(message)


exports.makeLogger = (module) ->
    new Logger(module)
