# Shared utility: detect Rails DSL calls in model/controller class bodies.
#
# Rails models and controllers use class-level DSL calls like:
#   has_many :comments, dependent: :destroy
#   validates :title, presence: true
#   before_action :set_article, only: [:show, :edit]
#
# These need to be recognized (and usually stripped) by language-specific filters.

require "compiler/crystal/syntax"

module Railcar
  RAILS_MODEL_DSL = Set{
    "has_many", "has_one", "belongs_to", "validates",
    "broadcasts_to", "broadcasts",
    "after_save", "after_destroy", "after_create", "after_update",
    "after_create_commit", "after_update_commit", "after_destroy_commit",
    "before_save", "before_destroy", "before_create", "before_update",
    "scope", "enum", "delegate", "accepts_nested_attributes_for",
  }

  RAILS_CONTROLLER_DSL = Set{
    "before_action", "after_action", "around_action",
    "skip_before_action", "skip_after_action",
    "rescue_from", "helper_method", "protect_from_forgery",
  }

  def self.rails_model_dsl?(node : Crystal::ASTNode) : Bool
    return false unless node.is_a?(Crystal::Call)
    call = node.as(Crystal::Call)
    return false if call.obj  # has a receiver — not a DSL call
    RAILS_MODEL_DSL.includes?(call.name)
  end

  def self.rails_controller_dsl?(node : Crystal::ASTNode) : Bool
    return false unless node.is_a?(Crystal::Call)
    call = node.as(Crystal::Call)
    return false if call.obj
    RAILS_CONTROLLER_DSL.includes?(call.name)
  end
end
