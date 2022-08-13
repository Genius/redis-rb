# frozen_string_literal: true

require "monitor"
require "redis/errors"
require "redis/commands"

class Redis
  BASE_PATH = __dir__
  Deprecated = Class.new(StandardError)

  class << self
    attr_accessor :silence_deprecations, :raise_deprecations

    def deprecate!(message)
      unless silence_deprecations
        if raise_deprecations
          raise Deprecated, message
        else
          ::Kernel.warn(message)
        end
      end
    end
  end

  include Commands

  SERVER_URL_OPTIONS = %i(url host port path).freeze

  # Create a new client instance
  #
  # @param [Hash] options
  # @option options [String] :url (value of the environment variable REDIS_URL) a Redis URL, for a TCP connection:
  #   `redis://:[password]@[hostname]:[port]/[db]` (password, port and database are optional), for a unix socket
  #    connection: `unix://[path to Redis socket]`. This overrides all other options.
  # @option options [String] :host ("127.0.0.1") server hostname
  # @option options [Integer] :port (6379) server port
  # @option options [String] :path path to server socket (overrides host and port)
  # @option options [Float] :timeout (5.0) timeout in seconds
  # @option options [Float] :connect_timeout (same as timeout) timeout for initial connect in seconds
  # @option options [String] :username Username to authenticate against server
  # @option options [String] :password Password to authenticate against server
  # @option options [Integer] :db (0) Database to select after connect and on reconnects
  # @option options [Symbol] :driver Driver to use, currently supported: `:ruby`, `:hiredis`
  # @option options [String] :id ID for the client connection, assigns name to current connection by sending
  #   `CLIENT SETNAME`
  # @option options [Integer, Array<Integer, Float>] :reconnect_attempts Number of attempts trying to connect,
  #   or a list of sleep duration between attempts.
  # @option options [Boolean] :inherit_socket (false) Whether to use socket in forked process or not
  # @option options [Array] :sentinels List of sentinels to contact
  # @option options [Symbol] :role (:master) Role to fetch via Sentinel, either `:master` or `:slave`
  # @option options [Array<String, Hash{Symbol => String, Integer}>] :cluster List of cluster nodes to contact
  # @option options [Boolean] :replica Whether to use readonly replica nodes in Redis Cluster or not
  # @option options [String] :fixed_hostname Specify a FQDN if cluster mode enabled and
  #   client has to connect nodes via single endpoint with SSL/TLS
  # @option options [Class] :connector Class of custom connector
  #
  # @return [Redis] a new client instance
  def initialize(options = {})
    @options = options.dup
    @options[:reconnect_attempts] = 1 unless @options.key?(:reconnect_attempts)
    if ENV["REDIS_URL"] && SERVER_URL_OPTIONS.none? { |o| @options.key?(o) }
      @options[:url] = ENV["REDIS_URL"]
    end
    inherit_socket = @options.delete(:inherit_socket)
    @cluster_mode = options.key?(:cluster)
    client = @cluster_mode ? Cluster : Client
    @original_client = @client = client.new(@options)
    @client.inherit_socket! if inherit_socket
    @queue = Hash.new { |h, k| h[k] = [] }
    @monitor = Monitor.new
  end

  # Run code without the client reconnecting
  def without_reconnect(&block)
    @original_client.disable_reconnection(&block)
  end

  # Test whether or not the client is connected
  def connected?
    @original_client.connected?
  end

  # Disconnect the client as quickly and silently as possible.
  def close
    @original_client.close
  end
  alias disconnect! close

  def with
    yield self
  end

  def _client
    @client
  end

  def pipelined
    synchronize do |client|
      client.pipelined do |raw_pipeline|
        yield PipelinedConnection.new(raw_pipeline)
      end
    end
  end

  def id
    @original_client.config.id || @original_client.config.server_url
  end

  def inspect
    "#<Redis client v#{Redis::VERSION} for #{id}>"
  end

  def dup
    self.class.new(@options)
  end

  def connection
    return @original_client.connection_info if @cluster_mode

    {
      host: @original_client.host,
      port: @original_client.port,
      db: @original_client.db,
      id: id,
      location: "#{@original_client.host}:#{@original_client.port}"
    }
  end

  private

  def synchronize
    @monitor.synchronize { yield(@client) }
  end

  def send_command(command, &block)
    @monitor.synchronize do
      @client.call(command, &block)
    end
  end

  def send_blocking_command(command, timeout, &block)
    @monitor.synchronize do
      @client.blocking_call(timeout, command, &block)
    end
  end

  def _subscription(method, timeout, channels, block)
    return @client.call([method] + channels) if subscribed?

    begin
      original, @client = @client, SubscribedClient.new(@client.pubsub)
      if timeout > 0
        @client.send(method, timeout, *channels, &block)
      else
        @client.send(method, *channels, &block)
      end
    ensure
      @client = original
    end
  end
end

require "redis/version"
require "redis/client"
require "redis/cluster"
require "redis/pipeline"
require "redis/subscribe"
