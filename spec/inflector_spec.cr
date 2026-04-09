require "spec"
require "../src/generator/inflector"

describe Railcar::Inflector do
  describe ".pluralize" do
    # Regular rules
    it("article → articles") { Railcar::Inflector.pluralize("article").should eq "articles" }
    it("comment → comments") { Railcar::Inflector.pluralize("comment").should eq "comments" }
    it("category → categories") { Railcar::Inflector.pluralize("category").should eq "categories" }
    it("bus → buses") { Railcar::Inflector.pluralize("bus").should eq "buses" }
    it("box → boxes") { Railcar::Inflector.pluralize("box").should eq "boxes" }
    it("quiz → quizzes") { Railcar::Inflector.pluralize("quiz").should eq "quizzes" }
    it("matrix → matrices") { Railcar::Inflector.pluralize("matrix").should eq "matrices" }
    it("vertex → vertices") { Railcar::Inflector.pluralize("vertex").should eq "vertices" }
    it("index → indices") { Railcar::Inflector.pluralize("index").should eq "indices" }
    it("mouse → mice") { Railcar::Inflector.pluralize("mouse").should eq "mice" }
    it("louse → lice") { Railcar::Inflector.pluralize("louse").should eq "lice" }
    it("ox → oxen") { Railcar::Inflector.pluralize("ox").should eq "oxen" }
    it("alias → aliases") { Railcar::Inflector.pluralize("alias").should eq "aliases" }
    it("status → statuses") { Railcar::Inflector.pluralize("status").should eq "statuses" }
    it("octopus → octopi") { Railcar::Inflector.pluralize("octopus").should eq "octopi" }
    it("virus → viri") { Railcar::Inflector.pluralize("virus").should eq "viri" }
    it("axis → axes") { Railcar::Inflector.pluralize("axis").should eq "axes" }
    it("testis → testes") { Railcar::Inflector.pluralize("testis").should eq "testes" }
    it("hive → hives") { Railcar::Inflector.pluralize("hive").should eq "hives" }
    it("half → halves") { Railcar::Inflector.pluralize("half").should eq "halves" }
    it("wolf → wolves") { Railcar::Inflector.pluralize("wolf").should eq "wolves" }
    it("tomato → tomatoes") { Railcar::Inflector.pluralize("tomato").should eq "tomatoes" }
    it("buffalo → buffaloes") { Railcar::Inflector.pluralize("buffalo").should eq "buffaloes" }
    it("crisis → crises") { Railcar::Inflector.pluralize("crisis").should eq "crises" }
    it("datum → data") { Railcar::Inflector.pluralize("datum").should eq "data" }

    # Irregulars
    it("person → people") { Railcar::Inflector.pluralize("person").should eq "people" }
    it("man → men") { Railcar::Inflector.pluralize("man").should eq "men" }
    it("woman → women") { Railcar::Inflector.pluralize("woman").should eq "women" }
    it("child → children") { Railcar::Inflector.pluralize("child").should eq "children" }

    # Uncountables
    it("equipment → equipment") { Railcar::Inflector.pluralize("equipment").should eq "equipment" }
    it("information → information") { Railcar::Inflector.pluralize("information").should eq "information" }
    it("sheep → sheep") { Railcar::Inflector.pluralize("sheep").should eq "sheep" }
    it("fish → fish") { Railcar::Inflector.pluralize("fish").should eq "fish" }
    it("species → species") { Railcar::Inflector.pluralize("species").should eq "species" }
    it("series → series") { Railcar::Inflector.pluralize("series").should eq "series" }

    # Capitalization preservation
    it("Person → People") { Railcar::Inflector.pluralize("Person").should eq "People" }

    # Already plural
    it("articles → articles") { Railcar::Inflector.pluralize("articles").should eq "articles" }
  end

  describe ".singularize" do
    # Regular rules
    it("articles → article") { Railcar::Inflector.singularize("articles").should eq "article" }
    it("comments → comment") { Railcar::Inflector.singularize("comments").should eq "comment" }
    it("categories → category") { Railcar::Inflector.singularize("categories").should eq "category" }
    it("buses → bus") { Railcar::Inflector.singularize("buses").should eq "bus" }
    it("boxes → box") { Railcar::Inflector.singularize("boxes").should eq "box" }
    it("quizzes → quiz") { Railcar::Inflector.singularize("quizzes").should eq "quiz" }
    it("matrices → matrix") { Railcar::Inflector.singularize("matrices").should eq "matrix" }
    it("vertices → vertex") { Railcar::Inflector.singularize("vertices").should eq "vertex" }
    it("indices → index") { Railcar::Inflector.singularize("indices").should eq "index" }
    it("mice → mouse") { Railcar::Inflector.singularize("mice").should eq "mouse" }
    it("lice → louse") { Railcar::Inflector.singularize("lice").should eq "louse" }
    it("oxen → ox") { Railcar::Inflector.singularize("oxen").should eq "ox" }
    it("aliases → alias") { Railcar::Inflector.singularize("aliases").should eq "alias" }
    it("statuses → status") { Railcar::Inflector.singularize("statuses").should eq "status" }
    it("octopi → octopus") { Railcar::Inflector.singularize("octopi").should eq "octopus" }
    it("viri → virus") { Railcar::Inflector.singularize("viri").should eq "virus" }
    it("axes → axis") { Railcar::Inflector.singularize("axes").should eq "axis" }
    it("testes → testis") { Railcar::Inflector.singularize("testes").should eq "testis" }
    it("hives → hive") { Railcar::Inflector.singularize("hives").should eq "hive" }
    it("halves → half") { Railcar::Inflector.singularize("halves").should eq "half" }
    it("wolves → wolf") { Railcar::Inflector.singularize("wolves").should eq "wolf" }
    it("tomatoes → tomato") { Railcar::Inflector.singularize("tomatoes").should eq "tomato" }
    it("crises → crisis") { Railcar::Inflector.singularize("crises").should eq "crisis" }
    it("data → datum") { Railcar::Inflector.singularize("data").should eq "datum" }
    it("analyses → analysis") { Railcar::Inflector.singularize("analyses").should eq "analysis" }
    it("movies → movie") { Railcar::Inflector.singularize("movies").should eq "movie" }
    it("shoes → shoe") { Railcar::Inflector.singularize("shoes").should eq "shoe" }
    it("databases → database") { Railcar::Inflector.singularize("databases").should eq "database" }
    it("news → news") { Railcar::Inflector.singularize("news").should eq "news" }

    # Irregulars
    it("people → person") { Railcar::Inflector.singularize("people").should eq "person" }
    it("men → man") { Railcar::Inflector.singularize("men").should eq "man" }
    it("women → woman") { Railcar::Inflector.singularize("women").should eq "woman" }
    it("children → child") { Railcar::Inflector.singularize("children").should eq "child" }

    # Uncountables
    it("equipment → equipment") { Railcar::Inflector.singularize("equipment").should eq "equipment" }
    it("sheep → sheep") { Railcar::Inflector.singularize("sheep").should eq "sheep" }

    # Capitalization preservation
    it("People → Person") { Railcar::Inflector.singularize("People").should eq "Person" }
  end

  describe ".classify" do
    it("articles → Article") { Railcar::Inflector.classify("articles").should eq "Article" }
    it("comments → Comment") { Railcar::Inflector.classify("comments").should eq "Comment" }
    it("access_tokens → AccessToken") { Railcar::Inflector.classify("access_tokens").should eq "AccessToken" }
    it("article → Article") { Railcar::Inflector.classify("article").should eq "Article" }
  end

  describe ".underscore" do
    it("Article → article") { Railcar::Inflector.underscore("Article").should eq "article" }
    it("AccessToken → access_token") { Railcar::Inflector.underscore("AccessToken").should eq "access_token" }
    it("HTMLParser → html_parser") { Railcar::Inflector.underscore("HTMLParser").should eq "html_parser" }
  end
end
