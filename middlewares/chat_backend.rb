require 'faye/websocket'
require 'thread'
require 'redis'
require 'json'
require 'erb'

module ChatDemo
  class ChatBackend
    KEEPALIVE_TIME = 15 # in seconds
    CHANNEL = "ALL"

    def initialize(app)
      @app     = app
      @clients = {}
      if ENV["REDISCLOUD_URL"]
        uri = URI.parse(ENV["REDISCLOUD_URL"])
        @redis = Redis.new(host: uri.host, port: uri.port, password: uri.password)
        Thread.new do
          redis_sub = Redis.new(host: uri.host, port: uri.port, password: uri.password)
          redis_sub.subscribe(CHANNEL) do |on|
            on.message do |channel, msg|
              msg = JSON.parse(msg)
              @clients[msg['room']].each {|ws| ws.send(msg['data']) }
            end
          end
        end
      else
        @redis = Class.new do # dummy redis for local
          attr_accessor :clients
          def publish(channel, msg)
            if channel == CHANNEL
              msg = JSON.parse(msg)
              @clients[msg['room']].each {|ws| ws.send(msg['data']) }
            end
          end
        end.new
        @redis.clients = @clients
      end
    end

    def call(env)
      if Faye::WebSocket.websocket?(env)
        room = env['REQUEST_URI'][/[\?&]room=([^&#]*)/, 1]

        ws = Faye::WebSocket.new(env, nil, {ping: KEEPALIVE_TIME})
        ws.on :open do |event|
          p [:open, room, ws.object_id]
          @clients[room] ||= []
          @clients[room] << ws
        end

        ws.on :message do |event|
          s = ""
          s += "#{room}: " if room!=nil && room!=""
          s += event.data
          puts s
          @redis.publish(CHANNEL, {'room'=>room, 'data'=>event.data}.to_json)
        end

        ws.on :close do |event|
          p [:close, room, ws.object_id, event.code, event.reason]
          @clients[room].delete(ws)
          ws = nil
        end

        # Return async Rack response
        ws.rack_response
      else
        @app.call(env)
      end
    end
  end
end
