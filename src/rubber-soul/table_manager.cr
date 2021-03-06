require "future"
require "habitat"
require "log"
require "promise"
require "rethinkdb-orm"
require "simple_retry"

require "./elastic"
require "./types"

# Class to manage rethinkdb models sync with elasticsearch
module RubberSoul
  class TableManager
    Log = ::Log.for("rubber-soul").for("table_manager")

    alias Property = Tuple(Symbol, NamedTuple(type: String))

    # Map class name to model properties
    getter properties : Hash(String, Array(Property)) = {} of String => Array(Property)

    # Map from class name to schema
    getter index_schemas : Hash(String, String) = {} of String => String

    # Class names of managed tables
    getter models : Array(String) = [] of String

    private getter coordination : Channel(Nil) = Channel(Nil).new

    macro finished
      # All RethinkORM models with abstract and empty classes removed
      # :nodoc:
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
        {% for klass, fields in MODELS %}
          {{ klass.stringify.split("::").last }} => {
              attributes: {
              {% for attr, options in fields %}
                {% options[:klass] = options[:klass].resolve if options[:klass].is_a?(Path) %}
                {% options[:klass] = options[:klass].stringify unless options[:klass].is_a?(StringLiteral) %}
                {{ attr.symbolize }} => {{ options }},
              {% end %}
              },
              table_name: {{ klass.id }}.table_name
            },
        {% end %}
      } {% if MODELS.empty? %} of Nil => Nil {% end %}
    end

    # TODO: Move away from String backed stores, use Class

    macro __generate_methods(methods)
      {% for method in methods %}
        __generate_method({{ method }})
      {% end %}
    end

    macro __generate_method(method)
      # Dispatcher for {{ method.id }}
      def {{ method.id }}(model)
        document_name = TableManager.document_name(model)
        # Generate {{ method.id }} method calls
        case document_name
        {% for klass in MODELS.keys %}
        when {{ klass.stringify.split("::").last }}
          {{ klass.id }}.{{ method.id }}(runopts: {"read_mode" => "majority"})
        {% end %}
        else
          raise "No #{ {{ method.stringify }} } for '#{model}'"
        end
      end
    end

    # Look up model schema by class
    def index_schema(model : Class | String) : String
      document_name = TableManager.document_name(model)
      index_schemas[TableManager.document_name(model)]
    end

    # Look up index name by class
    def index_name(model) : String
      MODEL_METADATA[TableManager.document_name(model)][:table_name]
    end

    # Initialisation
    #############################################################################################

    def initialize(
      klasses : Array(Class) = MANAGED_TABLES,
      backfill : Bool = false,
      watch : Bool = false
    )
      @models = klasses.map { |klass| TableManager.document_name(klass) }

      # Collate model properties
      @properties = generate_properties(models)

      # Generate schemas
      @index_schemas = generate_schemas(models)

      # Initialise indices to a consistent state
      initialise_indices(backfill)

      # Begin rethinkdb sync
      watch_tables(models) if watch
    end

    # Currently a reindex is triggered if...
    # - a single index does not exist
    # - a single mapping is different
    def initialise_indices(backfill : Bool = false)
      unless consistent_indices?
        Log.info { "reindexing all indices to consistency" }
        reindex_all
      end

      backfill_all if backfill
    end

    # Backfill
    #############################################################################################

    # Save all documents in all tables to the correct indices
    def backfill_all
      Promise.map(models) { |m| backfill(m) }.get
      Fiber.yield
    end

    # Backfills from a model to all relevant indices
    def backfill(model)
      Log.info { {message: "backfilling", model: model.to_s} }

      index = index_name(model)
      parents = parents(model)
      no_children = children(model).empty?

      backfill_count = 0

      all(model).in_groups_of(100).to_a.map do |docs|
        future {
          actions = docs.compact_map do |d|
            next unless d
            backfill_count += 1
            Elastic.document_request(
              action: Elastic::Action::Create,
              document: d,
              index: index,
              parents: parents,
              no_children: no_children,
            )
          end

          begin
            Elastic.bulk_operation(actions.join('\n'))
            Log.debug { {method: "backfill", model: model.to_s, subcount: actions.size} }
          rescue e
            Log.error(exception: e) { {method: "backfill", model: model.to_s, missed: actions.size} }
          end
        }
      end.each &.get
      Log.info { {method: "backfill", model: model.to_s, count: backfill_count} }
    end

    # Reindex
    #############################################################################################

    # Clear and update all index mappings
    def reindex_all
      Promise.map(models) { |m| reindex(m) }.get
      Fiber.yield
    end

    # Clear, update mapping an ES index and refill with rethinkdb documents
    def reindex(model : String | Class)
      Log.info { {method: "reindex", model: model.to_s} }
      name = TableManager.document_name(model)

      index = index_name(name)
      # Delete index
      Elastic.delete_index(index)
      # Apply current mapping
      create_index(name)
    rescue e
      Log.error(exception: e) { {method: "reindex", model: model.to_s} }
    end

    # Watch
    #############################################################################################

    def watch_tables(models)
      models.each do |model|
        spawn do
          watch_table(model)
        rescue e
          Log.error(exception: e) { {method: "watch_table", model: model.to_s} }
          # Fatal error
          exit 1
        end
      end
    end

    def stop
      coordination.close
    end

    def watch_table(model : String | Class)
      name = TableManager.document_name(model)

      index = index_name(name)
      parents = parents(name)
      no_children = children(name).empty?

      changefeed = nil
      spawn do
        coordination.receive?
        Log.warn { {method: "watch_table", message: "table_manager stopped"} }
        changefeed.try &.stop
      end

      # NOTE: in the event of losing connection, the table is backfilled.
      SimpleRetry.try_to(base_interval: 50.milliseconds, max_elapsed_time: 15.seconds) do |_, exception, _|
        begin
          handle_retry(model, exception)

          return if coordination.closed?
          changefeed = changes(name)
          Log.info { {method: "changes", model: model.to_s} }
          changefeed.not_nil!.each do |change|
            event = change[:event]
            document = change[:value]
            next if document.nil?

            Log.debug { {method: "watch_table", event: event.to_s.downcase, model: model.to_s, document_id: document.id, parents: parents} }

            # Asynchronously mutate Elasticsearch
            spawn do
              case event
              when RethinkORM::Changefeed::Event::Deleted
                Elastic.delete_document(
                  index: index,
                  document: document.not_nil!,
                  parents: parents,
                )
              when RethinkORM::Changefeed::Event::Created
                Elastic.create_document(
                  index: index,
                  document: document.not_nil!,
                  parents: parents,
                  no_children: no_children,
                )
              when RethinkORM::Changefeed::Event::Updated
                Elastic.update_document(
                  index: index,
                  document: document.not_nil!,
                  parents: parents,
                  no_children: no_children,
                )
              else raise Error.new
              end
            rescue e
              Log.warn(exception: e) { {message: "error while watching table", event: event.to_s.downcase} }
            end
          rescue e
            Log.error(exception: e) { "in watch_table" }
            changefeed.try &.stop
            raise e
          end
        end

        Fiber.yield
      end
    end

    private def handle_retry(model, exception : Exception?)
      if exception
        Log.warn(exception: exception) { {model: model.to_s, message: "backfilling after changefeed error"} }
        backfill(model)
      end
    rescue e
      Log.error(exception: e) { {model: model.to_s, message: "failed to backfill after changefeed dropped"} }
    end

    # Elasticsearch mapping
    #############################################################################################

    # Applies a schema to an index in elasticsearch
    #
    def create_index(model : String | Class)
      index = index_name(model)
      mapping = index_schema(model)

      Elastic.apply_index_mapping(index, mapping)
    end

    # Checks if any index does not exist or has a different mapping
    #
    def consistent_indices?
      models.all? do |model|
        Elastic.check_index?(index_name(model)) && !mapping_conflict?(model)
      end
    end

    # Diff the current mapping schema (if any) against provided mapping schema
    #
    def mapping_conflict?(model)
      proposed = index_schema(model)
      existing = Elastic.get_mapping?(index_name(model))

      equivalent = Elastic.equivalent_schema?(existing, proposed)
      Log.warn { {model: model.to_s, proposed: proposed, existing: existing, message: "index mapping conflict"} } unless equivalent

      !equivalent
    end

    # Schema Generation
    #############################################################################################

    # Generate a map of models to schemas
    def generate_schemas(models)
      schemas = {} of String => String
      models.each do |model|
        name = TableManager.document_name(model)
        schemas[name] = construct_document_schema(name)
      end
      schemas
    end

    private INDEX_SETTINGS = {
      analysis: {
        analyzer: {
          default: {
            tokenizer: "whitespace",
            filter:    ["lowercase", "preserved_ascii_folding"],
          },
        },
        filter: {
          preserved_ascii_folding: {
            type:              "asciifolding",
            preserve_original: true,
          },
        },
      },
    }

    # Generate the index type mapping structure
    def construct_document_schema(model) : String
      name = TableManager.document_name(model)
      children = children(name)
      properties = collect_index_properties(name, children)
      # Only include join if model has children
      properties = properties.merge(join_field(name, children)) unless children.empty?
      {
        settings: INDEX_SETTINGS,
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
      document_name = TableManager.document_name(model)
      properties = MODEL_METADATA[document_name][:attributes].compact_map do |field, options|
        type_tag = options.dig?(:tags, :es_type)
        if type_tag
          if !type_tag.is_a?(String) || !valid_es_type?(type_tag)
            raise Error.new("Invalid ES type '#{type_tag}' for #{field} of #{model}")
          end
          {field, {type: type_tag}}
        else
          # Map the klass of field to es_type
          es_type = klass_to_es_type(options[:klass])
          # Could the klass be mapped?
          es_type ? {field, {"type": es_type}} : nil
        end
      end
      properties << TYPE_PROPERTY
    end

    # Collects all properties relevant to an index and collapse them into a schema
    def collect_index_properties(model : String | Class, children : Array(String)? = [] of String)
      name = TableManager.document_name(model)
      index_models = children.dup << name
      # Get the properties of all relevent tables, create flat index properties
      properties.select(index_models).values.flatten.uniq.to_h
    end

    # Construct properties for given models
    def generate_properties(models)
      models.reduce({} of String => Array(Property)) do |props, model|
        name = TableManager.document_name(model)
        props[name] = generate_index_properties(name)
        props
      end
    end

    # Generate join fields for parent relations
    def join_field(model, children)
      relations = children.size == 1 ? children.first : children.sort
      {
        :join => {
          type:      "join",
          relations: {
            # Use types for defining the parent-child relation
            model => relations,
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

    private ES_MAPPINGS = {
      "Bool":    "boolean",
      "Float32": "float",
      "Float64": "double",
      "Int16":   "short",
      "Int32":   "integer",
      "Int64":   "long",
      "Int8":    "byte",
      "String":  "text",
      "Time":    "date",
    }

    # Map from a class type to an es type
    private def klass_to_es_type(klass_name) : String | Nil
      if klass_name.starts_with?("Array")
        collection_type(klass_name, "Array")
      elsif klass_name.starts_with?("Set")
        collection_type(klass_name, "Set")
      elsif klass_name == "JSON::Any" || klass_name.starts_with?("Hash") || klass_name.starts_with?("NamedTuple")
        "object"
      else
        es_type = ES_MAPPINGS[klass_name]?
        if es_type.nil?
          Log.warn { "no ES mapping for #{klass_name}" }
          nil
        else
          es_type
        end
      end
    end

    # Collections allowed as long as they are homogeneous
    private def collection_type(klass_name : String, collection_type : String)
      klass_to_es_type(klass_name.lchop("#{collection_type}(").rstrip(')'))
    end

    # Relations
    #############################################################################################

    # Find name and ES routing of document's parents
    def parents(model : Class | String) : Array(Parent)
      document_name = TableManager.document_name(model)
      MODEL_METADATA[document_name][:attributes].compact_map do |field, attr|
        parent_name = attr.dig? :tags, :parent
        if !parent_name.nil? && parent_name.is_a?(String)
          {
            name:         parent_name,
            index:        index_name(parent_name),
            routing_attr: field,
          }
        end
      end
    end

    # Get names of all children associated with model
    def children(model : Class | String)
      document_name = TableManager.document_name(model)
      MODEL_METADATA.compact_map do |name, metadata|
        # Ignore self
        next if name == document_name
        # Do any of the attributes define a parent relationship with current model?
        is_child = metadata[:attributes].any? do |_, attr_data|
          options = attr_data[:tags]
          !!(options && options[:parent]?.try { |p| p == document_name })
        end
        name if is_child
      end
    end

    # Property accessors via class

    def properties(klass : Class | String)
      properties[TableManager.document_name(klass)]
    end

    def index_schemas(klass : Class | String)
      index_schemas[TableManager.document_name(klass)]
    end

    # Utils
    #############################################################################################

    def cancel!
      raise Error.new("TableManager cancelled")
    end

    # Strips the namespace from the model
    def self.document_name(model)
      name = model.is_a?(Class) ? model.name : model
      name.split("::").last
    end
  end
end
