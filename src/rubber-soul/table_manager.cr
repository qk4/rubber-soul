require "logger"
require "habitat"
require "rethinkdb-orm"
require "retriable"

require "promise"

require "./elastic"
require "./types"

# Class to manage rethinkdb models sync with elasticsearch
module RubberSoul
  class TableManager
    alias Property = Tuple(Symbol, NamedTuple(type: String))

    Habitat.create do
      setting logger : Logger = Logger.new(STDOUT)
    end

    # Map class name to model properties
    @properties = {} of String => Array(Property)
    getter properties

    # Map from class name to schema
    @index_schemas = {} of String => String
    getter index_schemas

    # Class names of managed tables
    @models = [] of String
    getter models

    macro finished
      # All RethinkORM models with abstract and empty classes removed
      MODELS = {} of Nil => Nil
      __create_model_metadata
      __generate_methods([:changes, :all])
    end

    macro __create_model_metadata
      {% for model, fields in RethinkORM::Base::FIELD_MAPPINGS %}
        {% unless model.abstract? || fields.empty? %}
          {% if MANAGED_TABLES.map(&.resolve).includes?(model) %}
            {% MODELS[model] = fields %}
          {% end %}
        {% end %}
      {% end %}

      # Extracted metadata from ORM classes
      MODEL_METADATA = {
        {% for model, fields in MODELS %}
            {{ model.stringify.split("::").last }} => {
              attributes: {
              {% for attr, options in fields %}
                {{ attr.symbolize }} => {{ options }},
              {% end %}
              },
              table_name: {{ model.id }}.table_name
            },
        {% end %}
      } {% if MODELS.empty? %} of Nil => Nil {% end %}
    end

    macro __generate_methods(methods)
      {% for method in methods %}
        __generate_method({{ method }})
      {% end %}
    end

    macro __generate_method(method)
      # Dispatcher for {{ method.id }}
      def {{ method.id }}(model)
        # Generate {{ method.id }} method calls
        case model
        {% for klass in MODELS.keys %}
        when {{ klass.stringify.split("::").last }}
          {{ klass.id }}.{{ method.id }}
        {% end %}
        else
          raise "No #{ {{ method.stringify }} } for '#{model}'"
        end
      end
    end

    # Look up model schema by class
    def index_schema(model) : String
      @index_schemas[model]
    end

    # Look up index name by class
    def index_name(model) : String
      MODEL_METADATA[model][:table_name]
    end

    # Initialisation
    #############################################################################################

    def initialize(klasses = MANAGED_TABLES, backfill = false, watch = false)
      @models = klasses.map { |klass| strip_namespace(klass.name) }

      # Collate model properties
      @properties = generate_properties(@models)

      # Generate schemas
      @index_schemas = generate_schemas(@models)

      # Initialise indices to a consistent state
      initialise_indices(backfill)

      # Begin rethinkdb sync
      watch_tables(@models) if watch
    end

    # Currently a reindex is triggered if...
    # - a single index does not exist
    # - a single mapping is different
    def initialise_indices(backfill = false)
      reindex_all unless consistent_indices?
      backfill_all if backfill
    end

    # Backfill
    #############################################################################################

    # Backfills from a model to all relevant indices
    def backfill(model)
      self.settings.logger.info("Backfill: #{model}")

      index = index_name(model)
      parents = parents(model)
      children = children(model)
      all(model).each do |d|
        Elastic.save_document(
          index: index,
          parents: parents,
          children: children,
          document: d
        )
      end
      true
    end

    # Save all documents in all tables to the correct indices
    def backfill_all
      # Promise.all(
      #   @models.map { |model| Promise.defer { backfill(model) } }
      # ).get
      @models.each { |model| backfill(model) }
    end

    # Reindex
    #############################################################################################

    # Clear and update all index mappings
    def reindex_all
      # Promise.all(
      #   @models.map { |model| Promise.defer { reindex(model) } }
      # ).get
      @models.each { |model| reindex(model) }
    end

    # Clear, update mapping an ES index and refill with rethinkdb documents
    def reindex(model : String)
      self.settings.logger.info("Reindex: #{model}")

      index = index_name(model)
      # Delete index
      Elastic.delete_index(index)
      # Apply current mapping
      create_index(model)
    end

    # Watch
    #############################################################################################

    def watch_tables(models)
      models.each do |model|
        spawn do
          watch_table(model)
        rescue e
          self.settings.logger.error "While watching #{model}:\n #{e.inspect}"
          # Fatal error
          exit 1
        end
      end
    end

    def watch_table(model)
      index = index_name(model)
      parents = parents(model)
      children = children(model)

      # Exceptions to fail on
      no_retry = {
        Error     => nil,
        IO::Error => /Closed stream/,
      }

      # Retry on all exceptions excluding internal exceptions
      Retriable.retry(except: no_retry) do
        changes(model).each do |change|
          self.settings.logger.info("#{change[:event]}: #{model}")

          document = change[:value]
          next if document.nil?
          if change[:event] == RethinkORM::Changefeed::Event::Deleted
            Elastic.delete_document(document, index, parents, children)
          else
            Elastic.save_document(document, index, parents, children)
          end
        end
      end
    end

    # Elasticsearch mapping
    #############################################################################################

    # Checks if any index does not exist or has a different mapping
    def consistent_indices?
      @models.all? do |model|
        index = index_name(model)
        index_exists = Elastic.check_index?(index)
        index_exists && Elastic.same_mapping?(index, index_schema(model))
      end
    end

    # Applies a schema to an index in elasticsearch
    def create_index(model)
      index = index_name(model)
      mapping = index_schema(model)

      Elastic.apply_index_mapping(index, mapping)
    end

    # Schema Generation
    #############################################################################################

    # Generate a map of models to schemas
    def generate_schemas(models)
      schemas = {} of String => String
      models.each do |model|
        schemas[model] = construct_document_schema(model)
      end
      schemas
    end

    # Generate the index type mapping structure
    def construct_document_schema(model) : String
      children = children(model)
      properties = collect_index_properties(model, children)
      # Only include join if model has children
      properties = properties.merge(join_field(model, children)) unless children.empty?
      {
        mappings: {
          properties: properties,
        },
      }.to_json
    end

    # Property Generation
    #############################################################################################

    # Now that we are generating joins on the parent_id, we need to specify if we are generating
    # a child or a single document
    # Maps from crystal types to Elasticsearch field datatypes
    def generate_index_properties(model, child = false) : Array(Property)
      properties = MODEL_METADATA[model][:attributes].compact_map do |field, options|
        type_tag = options.dig?(:tags, :es_type)
        if type_tag
          unless valid_es_type?(type_tag)
            raise Error.new("Invalid ES type '#{type_tag}' for #{field} of #{model}")
          end
          {field, {type: type_tag}}
        else
          # Map the klass of field to es_type
          es_type = klass_to_es_type(options[:klass])
          # Could the klass be mapped?
          es_type ? {field, {type: es_type}} : nil
        end
      end
      properties << TYPE_PROPERTY
    end

    # Collects all properties relevant to an index and collapse them into a schema
    def collect_index_properties(model : String, children : Array(String)? = [] of String)
      index_models = children.dup << model
      # Get the properties of all relevent tables, create flat index properties
      @properties.select(index_models).values.flatten.uniq.to_h
    end

    # Construct properties for given models
    def generate_properties(models)
      models.reduce({} of String => Array(Property)) do |props, model|
        props[model] = generate_index_properties(model)
        props
      end
    end

    # Map from crystal types to Elasticsearch field datatypes
    def generate_index_properties(model) : Array(Property)
      properties = MODEL_METADATA[model][:attributes].compact_map do |field, options|
        type_tag = options.dig?(:tags, :es_type)
        if type_tag
          unless valid_es_type?(type_tag)
            raise Error.new("Invalid ES type '#{type_tag}' for #{field} of #{model}")
          end
          {field, {type: type_tag}}
        else
          # Map the klass of field to es_type
          es_type = klass_to_es_type(options[:klass])
          # Could the klass be mapped?
          es_type ? {field, {type: es_type}} : nil
        end
      end
      properties << TYPE_PROPERTY
    end

    # Generate join fields for parent relations
    def join_field(model, children)
      {
        :join => {
          type:      "join",
          relations: {
            # Use types for defining the parent-child relation
            model => children,
          },
        },
      }
    end

    # Allows several document types beneath a single index
    TYPE_PROPERTY = {:type, {type: "keyword"}}

    # Valid elasticsearch field datatypes
    private ES_TYPES = {
      # String
      "text", "keyword",
      # Numeric
      "long", "integer", "short", "byte", "double", "float", "half_float", "scaled_float",
      # Other
      "boolean", "date", "binary", "object",
      # Special
      "ip", "completion",
      # Spacial
      "geo_point", "geo_shape",
    }

    # Determine if type tag is a valid Elasticsearch field datatype
    private def valid_es_type?(es_type)
      ES_TYPES.includes?(es_type)
    end

    # Map from a class type to an es type
    private def klass_to_es_type(klass) : String | Nil
      case klass.name
      when "String"
        "text"
      when "Time"
        "date"
      when "Int64"
        "long"
      when "Int32"
        "integer"
      when "Int16"
        "short"
      when "Int8"
        "byte"
      when "Float64"
        "double"
      when "Float32"
        "float"
      else
        nil
      end
    end

    # Relations
    #############################################################################################

    # Find name and ES routing of document's parents
    def parents(model) : Array(Parent)
      MODEL_METADATA[model][:attributes].compact_map do |field, attr|
        parent_name = attr.dig? :tags, :parent
        unless parent_name.nil?
          {
            name:         parent_name,
            index:        index_name(parent_name),
            routing_attr: field,
          }
        end
      end
    end

    # Get names of all children associated with model
    def children(model)
      MODEL_METADATA.compact_map do |name, metadata|
        # Ignore self
        next if name == model
        # Do any of the attributes define a parent relationship with current model?
        is_child = metadata[:attributes].any? do |_, attr_data|
          options = attr_data[:tags]
          !!(options && options[:parent]?.try { |p| p == model })
        end
        name if is_child
      end
    end

    # Utils
    #############################################################################################

    def cancel!
      raise Error.new("TableManager cancelled")
    end

    private def strip_namespace(model)
      model.split("::").last
    end
  end
end
