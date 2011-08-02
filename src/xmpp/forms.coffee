xmpp = require('node-xmpp')
NS = require('./ns')

class exports.Field
    constructor: (@var='', @type='text-single', @label, value) ->
        @values = []
        if value
            @values.push value

    toXml: ->
        fieldAttrs = {}
        fieldAttrs.var ?= @var
        fieldAttrs.label ?= @label
        fieldAttrs.type ?= @type
        fieldEl = new xmpp.Element('field', fieldAttrs)
        addValue = (value) ->
            fieldEl.c('value').
                t(value)

        if not /-multi$/.test(@type) and @values[0]?
            addValue @values[0]
        else
            @values.forEach addValue

        fieldEl

class exports.Form
    constructor: (@type='result', formType) ->
        @fields = []
        if formType
            @fields.push new exports.Field('FORM_TYPE', 'hidden',
                undefined, formType)

    toXml: ->
        formEl = new xmpp.Element('form',
            xmlns: NS.DATA
            type: @type
        )
        @fields.forEach (field) ->
            formEl.cnode field.toXml()
        formEl
