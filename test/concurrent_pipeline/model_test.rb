# frozen_string_literal: true

require "test_helper"

module ConcurrentPipeline
  class ModelTest < Minitest::Test
    class ModelOne
      extend Model

      attribute :id
      attribute :name
    end

    class ModelTwo
      extend Model

      attribute :id
      attribute :other_name
    end

    class Child < ModelTwo
      attribute :child_attribute
    end

    def test_instance__attributes
      model = ModelOne.new({id: 1, name: "one"})
      assert_equal 1, model.id
      assert_equal "one", model.name
      refute model.respond_to?(:other_name)
      refute model.respond_to?(:child_attribute)

      model_2 = ModelTwo.new({id: 2, other_name: "two"})
      assert_equal 2, model_2.id
      assert_equal "two", model_2.other_name
      refute model_2.respond_to?(:name)
      refute model.respond_to?(:child_attribute)

      child = Child.new({id: 3, other_name: "three", child_attribute: "child"})
      assert_equal 3, child.id
      assert_equal "three", child.other_name
      assert_equal "child", child.child_attribute
    end

    def test_class__attributes
      assert_equal [:id, :name], ModelOne.attributes.keys.sort
      assert_equal [:id, :other_name], ModelTwo.attributes.keys.sort
      assert_equal [:child_attribute, :id, :other_name], Child.attributes.keys.sort
    end
  end
end
