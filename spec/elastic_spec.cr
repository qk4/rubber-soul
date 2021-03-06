require "./helper"

module RubberSoul
  describe Elastic do
    Spec.after_each do
      Elastic.empty_indices
    end

    it "routes to correct parent documents" do
      tm = TableManager.new(backfill: false, watch: false)

      child_index = Beverage::Coffee.table_name
      child_name = TableManager.document_name(Beverage::Coffee)
      parent_index = Programmer.table_name

      parent = Programmer.new(name: "Knuth")
      parent.id = RethinkORM::IdGenerator.next(parent)

      child = Beverage::Coffee.new
      child.programmer = parent
      child.id = RethinkORM::IdGenerator.next(child)

      # Save a child document in child and parent indices
      bulk_request = Elastic.document_request(
        action: Elastic::Action::Create,
        document: child,
        index: child_index,
        parents: tm.parents(child_name),
        no_children: tm.children(child_name).empty?,
      )

      Elastic.bulk_operation(bulk_request)

      headers, sources = bulk_request.split('\n').in_groups_of(2).transpose
      child_header, parent_header = headers.compact.map { |h| JSON.parse(h)["create"] }

      child_index_routing, parent_index_routing = sources.compact.map { |h| JSON.parse(h)["join"]? }

      child_index_routing.should be_nil

      name_field = parent_index_routing.not_nil!["name"]
      parent_field = parent_index_routing.not_nil!["parent"]

      # Ensure correct join field

      name_field.should eq TableManager.document_name(child.class)
      parent_field.should eq parent.id

      # Ensure child is routed via parent in parent table
      parent_header["routing"].to_s.should eq child.programmer_id
      child_header["routing"].to_s.should eq child.id

      parent_index_path = Elastic.document_path(index: parent_index, id: child.id)
      parent_index_doc = JSON.parse(Elastic.client &.get(parent_index_path).body)

      # Ensure child is routed via parent in parent table
      parent_index_doc["_routing"].to_s.should eq child.programmer_id
      parent_index_doc["_source"]["type"].should eq child_name

      # Pick off "type" and "join" fields, convert to any for easy comparison
      es_document = JSON.parse(parent_index_doc["_source"].as_h.reject("type", "join").to_json)
      local_document = JSON.parse(child.to_json)

      # Ensure document is the same across indices
      es_document.should eq local_document
    end

    describe "crud operation" do
      it "deletes a document" do
        index = Broke.table_name

        model = Broke.new(breaks: "Think")
        model.id = RethinkORM::IdGenerator.next(model)

        # Add a document to es
        Elastic.create_document(
          document: model,
          index: index,
        )

        es_doc_exists?(index, model.id, routing: model.id).should be_true

        # Delete a document from es
        Elastic.delete_document(
          document: model,
          index: index,
        )

        es_doc_exists?(index, model.id, routing: model.id).should be_false
      end

      it "deletes documents from associated indices" do
        index = Beverage::Coffee.table_name
        model_name = TableManager.document_name(Beverage::Coffee)

        tm = TableManager.new(backfill: false, watch: false)

        parents = tm.parents(model_name)
        parent_index = parents[0][:index]

        parent_model = Programmer.new(name: "Isaacs")
        parent_model.id = RethinkORM::IdGenerator.next(parent_model)

        model = Beverage::Coffee.new(temperature: 50)
        model.id = RethinkORM::IdGenerator.next(model)
        model.programmer = parent_model

        # Add document to es
        Elastic.create_document(
          document: model,
          index: index,
          parents: parents,
          no_children: tm.children(model_name).empty?,
        )

        until_expected(true) do
          es_doc_exists?(index, model.id, routing: model.id) && es_doc_exists?(parent_index, model.id, routing: parent_model.id)
        end

        # Remove document from es
        Elastic.delete_document(
          document: model,
          index: index,
          parents: parents,
        )

        until_expected(false) do
          es_doc_exists?(index, model.id, routing: model.id) || es_doc_exists?(parent_index, model.id, routing: parent_model.id)
        end
      end

      it "saves a document" do
        tm = TableManager.new(backfill: false, watch: false)
        index = Programmer.table_name
        model_name = TableManager.document_name(Programmer)

        model = Programmer.new(name: "tenderlove")
        model.id = RethinkORM::IdGenerator.next(model)

        parents = tm.parents(model_name)
        no_children = tm.children(model_name).empty?

        Elastic.create_document(
          document: model,
          index: index,
          parents: parents,
          no_children: no_children,
        )

        es_doc_exists?(index, model.id, routing: model.id).should be_true

        es_doc_url = Elastic.document_path(index: index, id: model.id)
        doc = JSON.parse(Elastic.client &.get(es_doc_url).body)

        # Ensure child is routed via parent in parent table
        doc["_routing"].to_s.should eq model.id
        doc["_source"]["type"].should eq model_name

        # Pick off "type" and "join" fields, convert to any for easy comparison
        es_document = JSON.parse(doc["_source"].as_h.reject("type", "join").to_json)
        local_document = JSON.parse(model.attributes.to_json)

        # Ensure local document is replicated in elasticsearch
        es_document.should eq local_document

        # Remove document
        Elastic.delete_document(index: index, document: model, parents: parents)
      end
    end
  end
end
