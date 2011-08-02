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

    getFormType: ->
        for field in @fields
            if field.var is 'FORM_TYPE'
                return field.values[0]
        null

    get: (fieldVar) ->
        console.log "get #{fieldVar}"
        for field in @fields
            if field.var is fieldVar
                console.log "get #{fieldVar} = #{field.values[0]}"
                return field.values[0]
        console.log "get #{fieldVar} = null"
        null

    toXml: ->
        formEl = new xmpp.Element('x',
            xmlns: NS.DATA
            type: @type
        )
        @fields.forEach (field) ->
            formEl.cnode field.toXml()
        formEl

exports.fromXml = (xEl) ->
    unless xEl.is('x', NS.DATA)
        console.warn "Importing non-form: #{xEl.toString()}"

    form = new exports.Form(xEl.attrs.type)
    form.fields = xEl.getChildren("field").map (fieldEl) ->
        field = new exports.Field(
            fieldEl.attrs.var,
            fieldEl.attrs.type,
            fieldEl.attrs.label
        )
        field.values = fieldEl.getChildren("value").map (valueEl) ->
            valueEl.getText()
        field
    form
