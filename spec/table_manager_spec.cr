require "./helper"

describe RubberSoul::TableManager do
  describe "mapping schema" do
    it "generates a schema for specs" do
      tm = RubberSoul::TableManager.new(SPEC_MODELS)
      programmer = tm.tables.find { |t| t.name == "Programmer" }

      programmer.should_not be_nil
      unless programmer.nil?
        schema = tm.create_schema(programmer)
        schema.should be_a(String)
      end
    end
  end

  describe "RethinkDB syncing" do
    it "creates ES documents from changefeed" do
      clear_test_indices
      tm = RubberSoul::TableManager.new(SPEC_MODELS) # ameba:disable Lint/UselessAssign

      es_document_count("programmer").should eq 0
      Programmer.create(name: "Rob Pike")
      sleep 1 # Wait for change to propagate to es
      es_document_count("programmer").should eq 1
    end
  end

  describe "reindex" do
    pending "applies current mapping" do
      delete_test_indices
      es = RubberSoul::Elastic.client

      get_schema = ->{ {mappings: JSON.parse(es.get("/programmer").body)["programmer"]["mappings"]}.to_json }
      wrong_schema = {
        mappings: {
          _doc: {
            properties: {
              wrong: {type: keyword},
            },
          },
        },
      }.to_json

      # Apply and check currently applied schema
      es.put("/programmer", RubberSoul::Elastic.headers, body: wrong_schema)
      get_schema.call.should eq wrong_schema
      tm = RubberSoul::TableManager.new(SPEC_MODELS)

      schema = tm.create_schema(programmer)
      updated_schema = get_schema.call

      # Check if updated schema applied
      updated_schema.should_not eq wrong_schema
      updated_schema.should eq schema
    end
  end

  describe "backfill" do
    it "refill a single es index with existing data in rethinkdb" do
      # Empty rethinkdb tables
      clear_test_tables
      (1..5).each do |n|
        Programmer.create(name: "Tim the #{n}th")
      end

      tm = RubberSoul::TableManager.new(SPEC_MODELS)

      # Remove documents from es
      clear_test_indices

      tm.backfill_all
      es_document_count("programmer").should eq 5
    end
  end
end
