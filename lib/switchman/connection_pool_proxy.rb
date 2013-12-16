module Switchman
  module ConnectionError
    def self.===(other)
      return true if defined?(PG::Error) && PG::Error === other
      false
    end
  end

  class ConnectionPoolProxy
    delegate :spec, :connected?, :default_schema, :with_connection,
             :to => :current_pool

    attr_reader :category

    def default_pool
      @default_pool
    end

    def initialize(category, default_pool, shard_connection_pools)
      @category = category
      @default_pool = default_pool
      @connection_pools = shard_connection_pools
    end

    def active_shard
      Shard.current(@category)
    end

    def active_shackles_environment
      Rails.env.test? ? :master : active_shard.database_server.shackles_environment
    end

    def current_pool
      pool = self.default_pool if active_shard.database_server == Shard.default.database_server && active_shackles_environment == :master && active_shard.database_server.shareable?
      pool = @connection_pools[pool_key] ||= create_pool unless pool
      pool.shard = active_shard
      pool
    end

    def connection
      pool = current_pool
      begin
        pool.connection
      rescue ConnectionError
        raise if active_shard.database_server == Shard.default.database_server && active_shackles_environment == :master
        configs = active_shard.database_server.config(active_shackles_environment)
        raise unless configs.is_a?(Array)
        configs.each_with_index do |config, idx|
          pool = create_pool(config.dup)
          begin
            connection = pool.connection
          rescue ConnectionError
            raise if idx == configs.length - 1
            next
          end
          @connection_pools[pool_key] = pool
          break connection
        end
      end
    end

    %w{release_connection disconnect! clear_reloadable_connections! verify_active_connections! clear_stale_cached_connections!}.each do |method|
      class_eval(<<-EOS)
          def #{method}
            @connection_pools.values.each(&:#{method})
          end
      EOS
    end

    protected

    def pool_key
      [active_shackles_environment,
        active_shard.database_server.shareable? ? active_shard.database_server.pool_key : active_shard]
    end

    def create_pool(config = nil)
      shard = active_shard
      unless config
        if shard != Shard.default
          config = shard.database_server.config(active_shackles_environment)
          config = config.first if config.is_a?(Array)
          config = config.dup
        else
          config = default_pool.spec.config
          if config[active_shackles_environment].is_a?(Hash)
            config = config.merge(config[active_shackles_environment])
          else
            config = config.dup
          end
        end
      end
      spec = ::ActiveRecord::Base::ConnectionSpecification.new(config, "#{config[:adapter]}_connection")
      # unfortunately the AR code that does this require logic can't really be
      # called in isolation
      require "active_record/connection_adapters/#{config[:adapter]}_adapter"

      ::ActiveRecord::ConnectionAdapters::ConnectionPool.new(spec).tap do |pool|
        pool.shard = shard
      end
    end
  end
end

