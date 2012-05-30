require 'securerandom'

# encoding: utf-8
module Dynamoid

  # Persistence is responsible for dumping objects to and marshalling objects from the datastore. It tries to reserialize
  # values to be of the same type as when they were passed in, based on the fields in the class.
  module Persistence
    extend ActiveSupport::Concern

    attr_accessor :new_record
    alias :new_record? :new_record

    module ClassMethods

      # Returns the name of the table the class is for.
      #
      # @since 0.2.0
      def table_name
        "#{Dynamoid::Config.namespace}_#{options[:name] ? options[:name] : self.name.downcase.pluralize}"
      end

      # Creates a table.
      #
      # @param [Hash] options options to pass for table creation
      # @option options [Symbol] :id the id field for the table
      # @option options [Symbol] :table_name the actual name for the table
      # @option options [Integer] :read_capacity set the read capacity for the table; does not work on existing tables
      # @option options [Integer] :write_capacity set the write capacity for the table; does not work on existing tables
      # @option options [Hash] {range_key => :type} a hash of the name of the range key and a symbol of its type
      #
      # @since 0.4.0
      def create_table(options = {})
        if self.range_key
          range_key_hash = { range_key => dynamo_type(attributes[range_key][:type]) }
        else
          range_key_hash = nil
        end
        options = {
          :id => self.hash_key,
          :table_name => self.table_name,
          :write_capacity => self.write_capacity,
          :read_capacity => self.read_capacity,
          :range_key => range_key_hash
        }.merge(options)

        return true if table_exists?(options[:table_name])

        Dynamoid::Adapter.tables << options[:table_name] if Dynamoid::Adapter.create_table(options[:table_name], options[:id], options)
      end

      # Does a table with this name exist?
      #
      # @since 0.2.0
      def table_exists?(table_name)
        Dynamoid::Adapter.tables.include?(table_name)
      end

      def from_database(attrs = {})
        new(attrs).tap { |r| r.new_record = false }
      end

      # Undump an object into a hash, converting each type from a string representation of itself into the type specified by the field.
      #
      # @since 0.2.0
      def undump(incoming = nil)
        incoming = (incoming || {}).symbolize_keys
        Hash.new.tap do |hash|
          self.attributes.each do |attribute, options|
            hash[attribute] = undump_field(incoming[attribute], options)
          end
          incoming.each {|attribute, value| hash[attribute] ||= value }
        end
      end

      # Undump a value for a given type. Given a string, it'll determine (based on the type provided) whether to turn it into a
      # string, integer, float, set, array, datetime, or serialized return value.
      #
      # @since 0.2.0
      def undump_field(value, options)
        if options[:default] && value.nil?
          value = options[:default]
        else
          return if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end

        case options[:type]
        when :string
          value.to_s
        when :integer
          value.to_i
        when :float
          value.to_f
        when :set, :array
          if value.is_a?(Set) || value.is_a?(Array)
            value
          else
            Set[value]
          end
        when :datetime
          if value.is_a?(Date) || value.is_a?(DateTime) || value.is_a?(Time)
            value
          else
            Time.at(value).to_datetime
          end
        when :serialized
          if value.is_a?(String)
            options[:serializer] ? options[:serializer].load(value) : YAML.load(value)
          else
            value
          end
        end
      end

      def dynamo_type(type)
        case type
        when :integer, :float, :datetime
          :number
        when :string, :serialized
          :string
        else
          raise 'unknown type'
        end
      end

    end

    # Set updated_at and any passed in field to current DateTime. Useful for things like last_login_at, etc.
    #
    def touch(name = nil)
      now = DateTime.now
      self.updated_at = now
      attributes[name] = now if name
      save
    end

    # Is this object persisted in the datastore? Required for some ActiveModel integration stuff.
    #
    # @since 0.2.0
    def persisted?
      !new_record?
    end

    # Run the callbacks and then persist this object in the datastore.
    #
    # @since 0.2.0
    def save(options = {})
      self.class.create_table

      if new_record?
        run_callbacks(:create) { persist }
      else
        persist
      end

      self
    end

    def update!(conditions = {}, &block)
      options = range_key ? {:range_key => attributes[range_key]} : {}
      new_attrs = Dynamoid::Adapter.update_item(self.class.table_name, self.hash_key, options.merge(:conditions => conditions), &block)
      load(new_attrs)
    end

    def update(conditions = {}, &block)
      update!(conditions, &block)
      true
    rescue Dynamoid::Errors::ConditionalCheckFailedException
      false
    end

    # Delete this object, but only after running callbacks for it.
    #
    # @since 0.2.0
    def destroy
      run_callbacks(:destroy) do
        self.delete
      end
      self
    end

    # Delete this object from the datastore and all indexes.
    #
    # @since 0.2.0
    def delete
      delete_indexes
      options = range_key ? {:range_key => attributes[range_key]} : {}
      Dynamoid::Adapter.delete(self.class.table_name, self.hash_key, options)
    end

    # Dump this object's attributes into hash form, fit to be persisted into the datastore.
    #
    # @since 0.2.0
    def dump
      Hash.new.tap do |hash|
        self.class.attributes.each do |attribute, options|
          hash[attribute] = dump_field(self.read_attribute(attribute), options)
        end
      end
    end

    private

    # Determine how to dump this field. Given a value, it'll determine how to turn it into a value that can be
    # persisted into the datastore.
    #
    # @since 0.2.0
    def dump_field(value, options)
      return if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      case options[:type]
      when :string
        value.to_s
      when :integer
        value.to_i
      when :float
        value.to_f
      when :set, :array
        if value.is_a?(Set) || value.is_a?(Array)
          value
        else
          Set[value]
        end
      when :datetime
        value.to_time.to_f
      when :serialized
        options[:serializer] ? options[:serializer].dump(value) : value.to_yaml
      end
    end

    # Persist the object into the datastore. Assign it an id first if it doesn't have one; then afterwards,
    # save its indexes.
    #
    # @since 0.2.0
    def persist
      run_callbacks(:save) do
        self.hash_key = SecureRandom.uuid if self.hash_key.nil? || self.hash_key.blank?
        Dynamoid::Adapter.write(self.class.table_name, self.dump)
        save_indexes
        @new_record = false
        true
      end
    end

  end

end
