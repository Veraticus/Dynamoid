# encoding: utf-8
require 'aws'

module Dynamoid
  module Adapter

    # The AwsSdk adapter provides support for the AWS-SDK for Ruby gem.
    # More information is available at that Gem's Github page:
    # https://github.com/amazonwebservices/aws-sdk-for-ruby
    #
    module AwsSdk
      extend self
      @@connection = nil

      # Establish the connection to DynamoDB.
      #
      # @return [AWS::DynamoDB::Connection] the raw DynamoDB connection
      #
      # @since 0.2.0
      def connect!
        @@connection = AWS::DynamoDB.new(:access_key_id => Dynamoid::Config.access_key, :secret_access_key => Dynamoid::Config.secret_key, :dynamo_db_endpoint => Dynamoid::Config.endpoint)
      end

      # Return the established connection.
      #
      # @return [AWS::DynamoDB::Connection] the raw DynamoDB connection
      #
      # @since 0.2.0
      def connection
        @@connection
      end

      # Get many items at once from DynamoDB. More efficient than getting each item individually.
      #
      # @example Retrieve IDs 1 and 2 from the table testtable
      #   Dynamoid::Adapter::AwsSdk.batch_get_item('table1' => ['1', '2'])
      #
      # @param [Hash] options the hash of tables and IDs to retrieve
      #
      # @return [Hash] a hash where keys are the table names and the values are the retrieved items
      #
      # @since 0.2.0
      def batch_get_item(options)
        hash = Hash.new{|h, k| h[k] = []}
        return hash if options.all?{|k, v| v.empty?}
        options.each do |t, ids|
          Array(ids).in_groups_of(100, false) do |group|
            batch = AWS::DynamoDB::BatchGet.new(:config => @@connection.config)
            batch.table(t, :all, Array(group)) unless group.nil? || group.empty?
            batch.each do |table_name, attributes|
              hash[table_name] << attributes.symbolize_keys!
            end
          end
        end
        hash
      end

      # Create a table on DynamoDB. This usually takes a long time to complete.
      #
      # @param [String] table_name the name of the table to create
      # @param [Symbol] key the table's primary key (defaults to :id)
      # @param [Hash] options provide a range_key here if you want one for the table
      #
      # @since 0.2.0
      def create_table(table_name, key = :id, options = {})
        Dynamoid.logger.info "Creating #{table_name} table. This could take a while."
        options[:hash_key] ||= {key.to_sym => :string}
        read_capacity = options[:read_capacity] || Dynamoid::Config.read_capacity
        write_capacity = options[:write_capacity] || Dynamoid::Config.write_capacity
        table = @@connection.tables.create(table_name, read_capacity, write_capacity, options)
        sleep 0.5 while table.status == :creating
        return table
      end

      # Removes an item from DynamoDB.
      #
      # @param [String] table_name the name of the table
      # @param [String] key the hash key of the item to delete
      # @param [Number] range_key the range key of the item to delete, required if the table has a composite key
      #
      # @since 0.2.0
      def delete_item(table_name, key, options = {})
        range_key = options.delete(:range_key)
        table = get_table(table_name)
        result = if table.composite_key?
          table.items.at(key, range_key)
        else
          table.items[key]
        end
        result.delete unless result.attributes.to_h.empty?
        true
      end

      # Deletes an entire table from DynamoDB. Only 10 tables can be in the deleting state at once,
      # so if you have more this method may raise an exception.
      #
      # @param [String] table_name the name of the table to destroy
      #
      # @since 0.2.0
      def delete_table(table_name)
        @@connection.tables[table_name].delete
      end

      # @todo Add a DescribeTable method.

      # Fetches an item from DynamoDB.
      #
      # @param [String] table_name the name of the table
      # @param [String] key the hash key of the item to find
      # @param [Number] range_key the range key of the item to find, required if the table has a composite key
      #
      # @return [Hash] a hash representing the raw item in DynamoDB
      #
      # @since 0.2.0



      def get_item(table_name, key, options = {})
        range_key = options.delete(:range_key)
        table = get_table(table_name)

        result = if table.composite_key?
          table.items.at(key, range_key)
        else
          table.items[key]
        end.attributes.to_h(options)
        if result.empty?
          nil
        else
          result.symbolize_keys!
        end
      end

      # List all tables on DynamoDB.
      #
      # @since 0.2.0
      def list_tables
        @@connection.tables.collect(&:name)
      end

      # Persists an item on DynamoDB.
      #
      # @param [String] table_name the name of the table
      # @param [Object] object a hash or Dynamoid object to persist
      #
      # @since 0.2.0
      def put_item(table_name, object)
        table = get_table(table_name)
        table.items.create(object.delete_if{|k, v| v.nil? || (v.respond_to?(:empty?) && v.empty?)})
      end

      # Query the DynamoDB table. This employs DynamoDB's indexes so is generally faster than scanning, but is
      # only really useful for range queries, since it can only find by one hash key at once. Only provide
      # one range key to the hash.
      #
      # @param [String] table_name the name of the table
      # @param [Hash] opts the options to query the table with
      # @option opts [String] :hash_value the value of the hash key to find
      # @option opts [Range] :range_value find the range key within this range
      # @option opts [Number] :range_greater_than find range keys greater than this
      # @option opts [Number] :range_less_than find range keys less than this
      # @option opts [Number] :range_gte find range keys greater than or equal to this
      # @option opts [Number] :range_lte find range keys less than or equal to this
      #
      # @return [Array] an array of all matching items
      #
      # @since 0.2.0
      def query(table_name, opts = {})
        table = get_table(table_name)

        consistent_opts = { :consistent_read => opts[:consistent_read] || false }
        if table.composite_key?
          results = []
          table.items.query(opts).each {|data| results << data.attributes.to_h(consistent_opts).symbolize_keys!}
          results
        else
          get_item(table_name, opts[:hash_value])
        end
      end

      # Scan the DynamoDB table. This is usually a very slow operation as it naively filters all data on
      # the DynamoDB servers.
      #
      # @param [String] table_name the name of the table
      # @param [Hash] scan_hash a hash of attributes: matching records will be returned by the scan
      #
      # @return [Array] an array of all matching items
      #
      # @since 0.2.0
      def scan(table_name, scan_hash, select_opts)
        table = get_table(table_name)
        results = []
        table.items.where(scan_hash).select(select_opts) do |data|
          results << data.attributes.symbolize_keys!
        end
        results
      end

      # @todo Add an UpdateItem method.

      # @todo Add an UpdateTable method.

      def get_table(table_name)
        unless table = table_cache[table_name]
          table = @@connection.tables[table_name]
          table.load_schema
          table_cache[table_name] = table
        end
        table
      end

      def table_cache
        @table_cache ||= {}
      end
    end
  end
end
