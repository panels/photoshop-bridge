express = require 'express'
WebSocketServer = require('ws').Server
{EventEmitter} = require 'events'
http = require 'http'
panelStatic = require 'panel-static'

EventEmitter.prototype._emit = EventEmitter.prototype.emit

module.exports =
class PhotoshopBridge extends EventEmitter
  constructor: ({@pkg, @generator}={}) ->
    @express = express
    @app = @express()

    @debugging = false

    server = http.createServer(@app)
    server.listen(@pkg.panel.port)

    # static files of panel that will be loaded in extension
    @app.use(panelStatic(@pkg.panel.static))

    # client js library to connect
    bridgePath = require.resolve('panel-bridge-client')
    @app.get '/_panels/bridge.js', (req, res) ->
      res.header 'Content-Type', 'application/javascript'
      res.sendfile bridgePath

    # rest fallback to send events
    @app.get '/_panels/emit-event', (req, res) =>
      query = req.query

      if query.type? and query.type in ['server-event', 'client-event', 'global-event'] and query.name?
        try
          params = JSON.parse query.params
        catch
          params = null

        # emit to panel
        if query.type in ['panel-event', 'global-event']
          @emit query.name, params, query.type

        # emit to server
        if query.type in ['server-event', 'global-event']
          @_emit(query.name, params)

        res.jsonp { status: 'ok' }
      else
        res.jsonp { status: 'fail' }

    # events that were emitted before panel connected
    @eventQueue = []

    @ws = new WebSocketServer({server})
    @ws.broadcast = (data) ->
      client.send(data) for client in @clients
    @ws.on 'connection', (ws) =>
      @registerSocketEventListeners(ws)
      @resolveEventQueue()

  registerSocketEventListeners: (panelSocket) ->
    panelSocket.on 'message', (message) =>
      try
        e = JSON.parse(message)
      catch e
        console.log('json prase')

      switch e.type
        when 'pair' then @handlePairing(e.params)
        when 'server-event', 'global-event' then @handlePanelEvent(e.name, e.params)
        when 'debug' then @startDebugging()

  handlePairing: (params) ->
    # ignored in Photoshop

  startDebugging: () ->
    return if @debugging
    @debugging = true

    esteWatch = require 'este-watch'
    staticDir = @pkg.panel.static

    watcher = esteWatch [staticDir], (e) =>
      e.filepath = e.filepath.replace staticDir, ''
      @emit 'reload', e, 'debug'

    watcher.start()

  resolveEventQueue: ->
    @ws.broadcast(e) for e in @eventQueue
    @eventQueue = []

  emit: (name, params = null, type = 'panel-event') ->
    data = JSON.stringify
      type: type
      name: name
      params: params

    if @ws.clients.length > 0
      @ws.broadcast data
    else
      @eventQueue.push data

  handlePanelEvent: (name, params) ->
    @_emit(name, params)
