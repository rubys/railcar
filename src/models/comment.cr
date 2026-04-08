require "../runtime/application_record"
require "../runtime/relation"
require "../runtime/collection_proxy"

module Ruby2CR
  class Comment < ApplicationRecord
    model "comments" do
      column article_id, Int64
      column commenter, String
      column body, String
      column created_at, Time
      column updated_at, Time

      belongs_to article, Article, foreign_key: "article_id"

      validates commenter, presence: true
      validates body, presence: true
    end

    private def run_validations
      self.class.validate_belongs_to_article(self)
      self.class.validate_presence_commenter(self)
      self.class.validate_presence_body(self)
    end
  end
end
