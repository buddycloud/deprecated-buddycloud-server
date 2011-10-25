winston = require 'winston'

exports.makeLogger = (filename) ->
    logger = winston.loggers.add filename,
        console:
            colorize: true
            level: "data@#{filename}"

    levels = {}
    colors = {}
    i = 0
    [['data', 'grey'],
     ['debug', 'brown'],
     ['info', 'green'],
     ['warn', 'yellow'],
     ['error', 'red']].forEach ([level1, color]) ->
        level = "#{level1}@#{filename}"
        console.log "#{level1} maps to #{level}"
        logger[level1] = (msg, context) ->
            @log level, msg, context
        levels[level] = i
        colors[level] = color
        i++
    console.log {logger,e:logger.error}

    logger.setLevels levels
    winston.addColors colors

    logger