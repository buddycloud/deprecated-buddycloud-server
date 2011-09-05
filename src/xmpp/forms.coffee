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
        for field in @fields
            if field.var is fieldVar
                return field.values[0]
        null

    addField: (var_, type, label, value) ->
        @fields.push new exports.Field(var_, type, label, value)

    toXml: ->
        formEl = new xmpp.Element('x',
            xmlns: NS.DATA
            type: @type
        )
        if @title?
            formEl.c('title').
                t(@title)
        if @instructions?
            formEl.c('instructions').
                t(@instructions)
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

exports.configToForm = (config, type, formType) ->
    form = new exports.Form(type, formType)
    addField = (key, fvar, label) ->
        if config[key]
            form.fields.push new exports.Field(fvar, 'text-single', label, config[key])
    addField 'title', 'pubsub#title',
        'A short name for the node'
    addField 'description', 'pubsub#description',
        'A description of the node'
    addField 'accessModel', 'pubsub#access_model',
        'Who may subscribe and retrieve items'
    addField 'publishModel', 'pubsub#publish_model',
        'Who may publish items'
    addField 'defaultAffiliation', 'pubsub#default_affiliation',
        'What role do new subscribers have?'
    form

exports.formToConfig = (form) ->
    config = null
    if (form.getFormType() is NS.PUBSUB_NODE_CONFIG or
        form.getFormType() is NS.PUBSUB_META_DATA) and
       (form.type is 'submit' or form.type is 'result')
        config = {}
        config.title ?= form.get('pubsub#title')
        config.description ?= form.get('pubsub#description')
        config.accessModel ?= form.get('pubsub#access_model')
        config.publishModel ?= form.get('pubsub#publish_model')
        config.defaultAffiliation ?= form.get('pubsub#default_affiliation')
    config
