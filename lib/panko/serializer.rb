require_relative 'attributes/base'
require_relative 'attributes/relationship'
require_relative 'attributes/has_one'
require_relative 'attributes/has_many'
require_relative 'cache'
require 'oj'

module Panko
  class Serializer
    class << self
      def inherited(base)
        base._attributes = (_attributes || []).dup
        base._associations = (_associations || []).dup

        @_attributes = []
        @_associations = []
      end

      attr_accessor :_attributes, :_associations

      def attributes(*attrs)
        @_attributes.push(*attrs)
      end


      def has_one(name, options)
        has_one_attr = HasOneAttribute.new(name, options)
        constantize_attribute(has_one_attr.const_name, has_one_attr.const_value)

        @_associations << has_one_attr
      end

      def has_many(name, options)
        has_many_attr = HasManyAttribute.new(name, options)
        constantize_attribute(has_many_attr.const_name, has_many_attr.const_value)

        @_associations << has_many_attr
      end


      #
      # Creates const for the given attr with it's name
      # frozen as value.
      #
      # This is for saving object allocations, so, instead of -
      # `obj["name"] = object.name`
      #
      # we do:
      # ```
      #   # once
      #   NAME = 'name'.freeze
      #
      #   # later
      #   obj[NAME] = object.name
      # ```
      def constantize_attribute(const_name, value)
        const_set(const_name, value.freeze) unless const_defined?(const_name)
      end
    end

    def initialize(options = {})
      @context = options.fetch(:context, nil)

      processed_filter = process_filter options.fetch(:only, [])
      @only = processed_filter[:serializer]
      @only_associations = processed_filter[:associations]

      processed_filter = process_filter options.fetch(:except, [])
      @except = processed_filter[:serializer]
      @except_associations = processed_filter[:associations]

      @attributes = []
      @method_call_attributes = []

      build_attributes_reader
    end

    attr_reader :object, :context
    attr_writer :context

    def serialize(object, writer = nil)
      Oj.load(serialize_to_json(object, writer))
    end

    def serialize_to_json(object, writer = nil)
      writer ||= Oj::StringWriter.new(mode: :rails)
      serialize_to_writer object, writer

      writer.to_s
    end

    private

    def process_filter(filter)
      return { serializer: filter, associations: {} } if filter.is_a? Array

      if filter.is_a? Hash
        # hash filters looks like this
        # { instance: [:a], foo: [:b] }
        # which mean, for the current instance use `[:a]` as filter
        # and for association named `foo` use `[:b]`

        return {
          serializer: filter.fetch(:instance, []),
          associations: filter.except(:instance)
        }
      end
    end

    def build_attributes_reader
      build_attributes_metadata

      attributes_reader_method_body = <<-EOMETHOD
        def serialize_to_writer object, writer
          @object = object

          writer.push_object

          Panko::process(object, writer, self, @attributes, @method_call_attributes)
          #{associations_code}

          writer.pop
        end
      EOMETHOD


      instance_eval attributes_reader_method_body, __FILE__, __LINE__
    end

    def build_attributes_metadata
      filter_attributes(self.class._attributes).each do |attr|
        if self.class.method_defined? attr
          @method_call_attributes << attr
        else
          @attributes << attr
        end
      end
    end

    def associations_code
      filter_associations(self.class._associations).map do |association|
        #
        # Create instance variable to store the serializer for reusing of serializer.
        #
        # Example:
        #   For `has_one :foo, serializer: FooSerializer`
        #   @foo_serializer = FooSerializer.new
        #
        options = {
          context: @context,
          only: @only_associations.fetch(association.name, []),
          except: @except_associations.fetch(association.name, [])
        }

        serializer = association.create_serializer(options)
        instance_variable_set association.serializer_name, serializer

        association.code
      end.join("\n".freeze)
    end

    def filter_associations(keys)
      unless @only.empty?
        return keys.select { |key| @only.include? key.name }
      end

      unless @except.empty?
        return keys.reject { |key| @except.include? key.name }
      end

      keys
    end

    def filter_attributes(keys)
      unless @only.empty?
        return keys.select { |key| @only.include?(key) }
      end

      unless @except.empty?
        return keys.reject { |key| @except.include?(key) }
      end

      keys
    end
  end
end
