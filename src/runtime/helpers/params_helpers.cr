# Strong parameters helper — mirrors Rails params.expect/permit.
# Extracts nested params from Kemal's env.params.body.

module Railcar::ParamsHelpers
  # Extract a hash of allowed parameters from form body.
  # Mirrors: params.expect(article: [:title, :body])
  def expect_params(env, model_name : String, fields : Array(String)) : Hash(String, String)
    result = {} of String => String
    fields.each do |field|
      key = "#{model_name}[#{field}]"
      value = env.params.body[key]?
      result[field] = value.to_s if value
    end
    result
  end
end
