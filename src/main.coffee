fs = require 'fs'
express = require 'express'
WebSocketServer = require('ws').Server
{EventEmitter} = require 'events'
http = require 'http'
panelStatic = require 'panel-static'
color = require 'bash-color'
bodyParser = require 'body-parser'

err = (msg) ->
  console.log ''
  console.log "#{color.red('[panel-photoshop-bridge]')} #{msg}"
  console.log ''

EventEmitter.prototype._emit = EventEmitter.prototype.emit

module.exports =
class PhotoshopBridge extends EventEmitter
  constructor: ({@pkg, @generator}={}) ->
    @express = express
    @app = @express()

    @app.use bodyParser.json()

    @debugging = false

    @app.get '/', (req, res) =>
      res.send """
        <meta charset="utf-8">
        <style>*{font-family:sans-serif;color:#333}body{width:500px;margin:100px auto 0}p{line-height:27px;font-size:14px}h1{font-size:25px}</style>
        <h1>#{@pkg.panel.title} Photoshop Plugin</h1>
        <p>Hey, this is an internal server that powers your #{@pkg.panel.title} Photoshop Plugin.</p>
        <p>It works only when your Photoshop is running, it doesn't allow any external connections from network and it has almost zero impact on Photoshop performance. You don't really need to worry about it, it should just work.</p>
        <p><small>If you are more of a techie, let's open <a href="/panel/?platform=chrome">/panel/</a> in your browser and see the magic :)</small></p>
      """

    # static files of panel that will be loaded in extension
    unless fs.existsSync(@pkg.panel.static)
      err "Static folder (#{@pkg.panel.static}) not found. Haven't you forgot to link it?"
    else
      @app.use('/panel', panelStatic(@pkg.panel.static))

    server = http.createServer(@app)
    server.listen(@pkg.panel.port, '127.0.0.1')

    # client js library to connect
    bridgePath = require.resolve('panel-bridge-client')
    @app.get '/_panels/bridge.js', (req, res) ->
      res.header 'Content-Type', 'application/javascript'
      res.sendFile bridgePath

    @app.get '/_panels/ping', (req, res) ->
      res.jsonp 'pong'

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
