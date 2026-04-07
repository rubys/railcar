require "../runtime/application_record"
require "../runtime/relation"
require "../runtime/collection_proxy"

module Ruby2CR
  class Article < ApplicationRecord
    model "articles" do
      column title, String
      column body, String
      column created_at, Time
      column updated_at, Time

      has_many comments, Comment, foreign_key: "article_id", dependent: :destroy

      validates title, presence: true
      validates body, presence: true, length: {minimum: 10}
    end

    private def run_validations
      self.class.validate_presence_title(self)
      self.class.validate_presence_body(self)
      self.class.validate_length_body(self)
    end

    def destroy : Bool
      # dependent: :destroy — delete comments first
      comments.destroy_all
      super
    end
  end
end
