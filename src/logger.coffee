CommonLogger = require 'common-logger'
ain2 = require 'ain2'
fs = require 'fs'

config = {}
logFile = undefined
exports.setConfig = (config_) ->
    config = config_
    if config_.file
        logFile = fs.createWriteStream config_.file
    if config_.syslog?
        ain2.set
            tag: 'buddycloud'
            facility: 'daemon'
        if config_.syslog.hostname
            ain2.set hostname: config_.syslog.hostname
        if config_.syslog.port
            ain2.set port: config_.syslog.port

class Logger extends CommonLogger
    constructor: (@module) ->
        # Translate user-passed string to level index
        config.level = CommonLogger.levels.indexOf config.level
        super(config)

    # + @module output
    format: (date, level, message) ->
        "[#{date.toUTCString()}] #{@constructor.levels[level]} [#{@module}] #{message}"

    # Monkey patch to pass level to @out()
    log: (level, args) ->
        if level <= @level
            i       = 0
            message = args[0].replace /%s/g, -> args[i++]
            message = @format(new Date(), level, message)
            message = @colorize(message, @colors[level]) if @colorized
            @out message, level

    # more targets than just console.log()
    out: (message, level) ->
        if config.stdout
            console.log message
        if logFile
            logFile.write "#{message}\n"
        if config.syslog?
            levelName = CommonLogger.levels[level]?.toLowerCase()
            console.log {levelName,level}
            if levelName and ain2[levelName]
                ain2[levelName] message


exports.makeLogger = (module) ->
    new Logger(module)
