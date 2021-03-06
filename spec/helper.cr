require "json"
require "promise"
require "simple_retry"
require "spec"

# Application config
require "./spec_config"

require "../src/rubber-soul/*"
require "../src/api"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

macro table_names
  [{% for klass in RubberSoul::MANAGED_TABLES %} {{ klass }}.table_name, {% end %}]
end

Spec.before_suite do
  ::Log.setup "*", :debug, RubberSoul::LOG_BACKEND
end

Spec.before_suite &->cleanup
Spec.after_suite &->cleanup

def until_expected(expected)
  before = Time.utc
  success = begin
    SimpleRetry.try_to(
      base_interval: 100.milliseconds,
      max_interval: 500.milliseconds,
      max_elapsed_time: 10.seconds,
      retry_on: Exception
    ) do
      result = yield

      if result != expected
        Log.error { "retry: expected #{expected}, got #{result}" }
        raise Exception.new("retry")
      else
        true
      end
    end
  rescue e
    raise e unless e.message == "retry"
    false
  ensure
    after = Time.utc
    Log.info { "took #{(after - before).total_milliseconds}ms" }
  end

  !!success
end

def cleanup
  # Empty rethinkdb test tables
  drop_tables
  # Remove any of the test indices
  clear_test_indices
  delete_test_indices
end

def drop_tables
  RethinkORM::Connection.raw do |q|
    q.db("test").table_list.for_each do |t|
      q.db("test").table(t).delete
    end
  end
end

# Remove all documents from an index, retaining index mappings
def clear_test_indices
  Promise.map(table_names) do |name|
    RubberSoul::Elastic.empty_indices([name])
  end.get
  Fiber.yield
end

# Delete all test indices on start up
def delete_test_indices
  Promise.map(table_names) do |name|
    RubberSoul::Elastic.delete_index(name)
  end.get
  Fiber.yield
end

macro clear_test_tables
  {% for klass in RubberSoul::MANAGED_TABLES %}
  {{ klass.id }}.clear
  {% end %}
end

# Helper to get document count for an es index
def es_document_count(index)
  response_body = JSON.parse(RubberSoul::Elastic.client &.get("/#{index}/_count").body)
  response_body["count"].as_i
end

def es_doc_exists?(index, id, routing)
  RubberSoul::Elastic.client &.get("/#{index}/_doc/#{id}").success?
end
