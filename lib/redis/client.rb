# frozen_string_literal: true

require 'redis-client'

class Redis
  class Client < ::RedisClient
    ERROR_MAPPING = {
      RedisClient::ConnectionError => Redis::ConnectionError,
      RedisClient::CommandError => Redis::CommandError,
      RedisClient::ReadTimeoutError => Redis::TimeoutError,
      RedisClient::CannotConnectError => Redis::CannotConnectError,
      RedisClient::AuthenticationError => Redis::CannotConnectError,
      RedisClient::PermissionError => Redis::PermissionError,
      RedisClient::WrongTypeError => Redis::WrongTypeError,
      RedisClient::RESP3::UnknownType => Redis::ProtocolError,
    }.freeze

    class << self
      def config(**kwargs)
        ::RedisClient.config(protocol: 2, **kwargs)
      end
    end

    def initialize(*)
      super
      @inherit_socket = false
      @pid = Process.pid
    end
    ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)

    def server_url
      config.server_url
    end

    def timeout
      config.read_timeout
    end

    def db
      config.db
    end

    def host
      config.host unless config.path
    end

    def port
      config.port unless config.path
    end

    def path
      config.path
    end

    def username
      config.username
    end

    def password
      config.password
    end

    def call(command, &block)
      super(*command, &block)
    rescue ::RedisClient::Error => error
      raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
    end

    def multi
      super
    rescue ::RedisClient::Error => error
      raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
    end

    def pipelined
      super
    rescue ::RedisClient::Error => error
      raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
    end

    def blocking_call(timeout, command, &block)
      timeout += self.timeout if timeout && timeout > 0
      super(timeout, *command, &block)
    rescue ::RedisClient::Error => error
      raise ERROR_MAPPING.fetch(error.class), error.message, error.backtrace
    end

    def disable_reconnection(&block)
      ensure_connected(retryable: false, &block)
    end

    def inherit_socket!
      @inherit_socket = true
    end

    private

    def ensure_connected(retryable: true)
      unless @inherit_socket || Process.pid == @pid
        raise InheritedError,
              "Tried to use a connection from a child process without reconnecting. " \
              "You need to reconnect to Redis after forking " \
              "or set :inherit_socket to true."
      end

      super
    end
  end
end
