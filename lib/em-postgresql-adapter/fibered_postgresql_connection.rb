require 'fiber'
require 'eventmachine'
require 'pg'

module EM
  module DB
    # Patching our PGConn-based class to wrap async_exec (alias for async_query) calls into Ruby Fibers
    # ActiveRecord 3.1 calls PGConn#async_exec and also PGConn#send_query_prepared (the latter hasn't been patched here yet -- see below)
    class FiberedPostgresConnection < PG::Connection

      module Watcher
        def initialize(client, deferrable)
          @client = client
          @deferrable = deferrable
        end

        def notify_readable
          detach
          begin
            @client.block
            @deferrable.succeed(@client.get_last_result)
          rescue Exception => e
            @deferrable.fail(e)
          end
        end
      end

      def send_query_using_fibers(sql, *opts)
        send_query(sql, *opts)

        deferrable = ::EM::DefaultDeferrable.new
        ::EM.watch(self.socket, Watcher, self, deferrable).notify_readable = true

        f = Fiber.current
        deferrable.callback { |res| f.resume(res) }
        deferrable.errback  { |err| f.resume(err) }

        Fiber.yield.tap do |result|
          raise result if result.is_a?(Exception)
        end
      end

      def try_query_using_fibers(sql, *opts)
        if ::EM.reactor_running?
          send_query_using_fibers(sql, *opts)
        else
          async_exec(sql, *opts)
        end
      end

      # TODO: Figure out whether patching PGConn#send_query_prepared will have a noticeable effect and implement accordingly
      # NOTE: ActiveRecord 3.1 calls PGConn#send_query_prepared from ActiveRecord::ConnectionAdapters::PostgreSQLAdapter#exec_cache.
      # def send_query_prepared(statement_name, *params)
      # end

      # When the connection is in use
      # but the connection pool has been requested to prepare a statement
      # this metho is called to store the preparation instructions until
      # the connection is released to the pool
      def postpone(*args, &blk)
        @postponed_queries=[] unless @postponed_queries.is_a? Array
        @postponed_queries.push({:args => args, :blk => blk})
      end

      def run_postponed_queries
        @postponed_queries=[] unless @postponed_queries.is_a? Array
        postponed_query=@postponed_queries.pop
        until postponed_query.nil? do
          prepare(*postponed_query[:args], &postponed_query[:blk])
          postponed_query=@postponed_queries.pop
        end
      end

    end #FiberedPostgresConnection
  end #DB
end #EM
