require "spec"
require "../src/generator/inflector"

describe Ruby2CR::Inflector do
  describe ".pluralize" do
    # Regular rules
    it("article → articles") { Ruby2CR::Inflector.pluralize("article").should eq "articles" }
    it("comment → comments") { Ruby2CR::Inflector.pluralize("comment").should eq "comments" }
    it("category → categories") { Ruby2CR::Inflector.pluralize("category").should eq "categories" }
    it("bus → buses") { Ruby2CR::Inflector.pluralize("bus").should eq "buses" }
    it("box → boxes") { Ruby2CR::Inflector.pluralize("box").should eq "boxes" }
    it("quiz → quizzes") { Ruby2CR::Inflector.pluralize("quiz").should eq "quizzes" }
    it("matrix → matrices") { Ruby2CR::Inflector.pluralize("matrix").should eq "matrices" }
    it("vertex → vertices") { Ruby2CR::Inflector.pluralize("vertex").should eq "vertices" }
    it("index → indices") { Ruby2CR::Inflector.pluralize("index").should eq "indices" }
    it("mouse → mice") { Ruby2CR::Inflector.pluralize("mouse").should eq "mice" }
    it("louse → lice") { Ruby2CR::Inflector.pluralize("louse").should eq "lice" }
    it("ox → oxen") { Ruby2CR::Inflector.pluralize("ox").should eq "oxen" }
    it("alias → aliases") { Ruby2CR::Inflector.pluralize("alias").should eq "aliases" }
    it("status → statuses") { Ruby2CR::Inflector.pluralize("status").should eq "statuses" }
    it("octopus → octopi") { Ruby2CR::Inflector.pluralize("octopus").should eq "octopi" }
    it("virus → viri") { Ruby2CR::Inflector.pluralize("virus").should eq "viri" }
    it("axis → axes") { Ruby2CR::Inflector.pluralize("axis").should eq "axes" }
    it("testis → testes") { Ruby2CR::Inflector.pluralize("testis").should eq "testes" }
    it("hive → hives") { Ruby2CR::Inflector.pluralize("hive").should eq "hives" }
    it("half → halves") { Ruby2CR::Inflector.pluralize("half").should eq "halves" }
    it("wolf → wolves") { Ruby2CR::Inflector.pluralize("wolf").should eq "wolves" }
    it("tomato → tomatoes") { Ruby2CR::Inflector.pluralize("tomato").should eq "tomatoes" }
    it("buffalo → buffaloes") { Ruby2CR::Inflector.pluralize("buffalo").should eq "buffaloes" }
    it("crisis → crises") { Ruby2CR::Inflector.pluralize("crisis").should eq "crises" }
    it("datum → data") { Ruby2CR::Inflector.pluralize("datum").should eq "data" }

    # Irregulars
    it("person → people") { Ruby2CR::Inflector.pluralize("person").should eq "people" }
    it("man → men") { Ruby2CR::Inflector.pluralize("man").should eq "men" }
    it("woman → women") { Ruby2CR::Inflector.pluralize("woman").should eq "women" }
    it("child → children") { Ruby2CR::Inflector.pluralize("child").should eq "children" }

    # Uncountables
    it("equipment → equipment") { Ruby2CR::Inflector.pluralize("equipment").should eq "equipment" }
    it("information → information") { Ruby2CR::Inflector.pluralize("information").should eq "information" }
    it("sheep → sheep") { Ruby2CR::Inflector.pluralize("sheep").should eq "sheep" }
    it("fish → fish") { Ruby2CR::Inflector.pluralize("fish").should eq "fish" }
    it("species → species") { Ruby2CR::Inflector.pluralize("species").should eq "species" }
    it("series → series") { Ruby2CR::Inflector.pluralize("series").should eq "series" }

    # Capitalization preservation
    it("Person → People") { Ruby2CR::Inflector.pluralize("Person").should eq "People" }

    # Already plural
    it("articles → articles") { Ruby2CR::Inflector.pluralize("articles").should eq "articles" }
  end

  describe ".singularize" do
    # Regular rules
    it("articles → article") { Ruby2CR::Inflector.singularize("articles").should eq "article" }
    it("comments → comment") { Ruby2CR::Inflector.singularize("comments").should eq "comment" }
    it("categories → category") { Ruby2CR::Inflector.singularize("categories").should eq "category" }
    it("buses → bus") { Ruby2CR::Inflector.singularize("buses").should eq "bus" }
    it("boxes → box") { Ruby2CR::Inflector.singularize("boxes").should eq "box" }
    it("quizzes → quiz") { Ruby2CR::Inflector.singularize("quizzes").should eq "quiz" }
    it("matrices → matrix") { Ruby2CR::Inflector.singularize("matrices").should eq "matrix" }
    it("vertices → vertex") { Ruby2CR::Inflector.singularize("vertices").should eq "vertex" }
    it("indices → index") { Ruby2CR::Inflector.singularize("indices").should eq "index" }
    it("mice → mouse") { Ruby2CR::Inflector.singularize("mice").should eq "mouse" }
    it("lice → louse") { Ruby2CR::Inflector.singularize("lice").should eq "louse" }
    it("oxen → ox") { Ruby2CR::Inflector.singularize("oxen").should eq "ox" }
    it("aliases → alias") { Ruby2CR::Inflector.singularize("aliases").should eq "alias" }
    it("statuses → status") { Ruby2CR::Inflector.singularize("statuses").should eq "status" }
    it("octopi → octopus") { Ruby2CR::Inflector.singularize("octopi").should eq "octopus" }
    it("viri → virus") { Ruby2CR::Inflector.singularize("viri").should eq "virus" }
    it("axes → axis") { Ruby2CR::Inflector.singularize("axes").should eq "axis" }
    it("testes → testis") { Ruby2CR::Inflector.singularize("testes").should eq "testis" }
    it("hives → hive") { Ruby2CR::Inflector.singularize("hives").should eq "hive" }
    it("halves → half") { Ruby2CR::Inflector.singularize("halves").should eq "half" }
    it("wolves → wolf") { Ruby2CR::Inflector.singularize("wolves").should eq "wolf" }
    it("tomatoes → tomato") { Ruby2CR::Inflector.singularize("tomatoes").should eq "tomato" }
    it("crises → crisis") { Ruby2CR::Inflector.singularize("crises").should eq "crisis" }
    it("data → datum") { Ruby2CR::Inflector.singularize("data").should eq "datum" }
    it("analyses → analysis") { Ruby2CR::Inflector.singularize("analyses").should eq "analysis" }
    it("movies → movie") { Ruby2CR::Inflector.singularize("movies").should eq "movie" }
    it("shoes → shoe") { Ruby2CR::Inflector.singularize("shoes").should eq "shoe" }
    it("databases → database") { Ruby2CR::Inflector.singularize("databases").should eq "database" }
    it("news → news") { Ruby2CR::Inflector.singularize("news").should eq "news" }

    # Irregulars
    it("people → person") { Ruby2CR::Inflector.singularize("people").should eq "person" }
    it("men → man") { Ruby2CR::Inflector.singularize("men").should eq "man" }
    it("women → woman") { Ruby2CR::Inflector.singularize("women").should eq "woman" }
    it("children → child") { Ruby2CR::Inflector.singularize("children").should eq "child" }

    # Uncountables
    it("equipment → equipment") { Ruby2CR::Inflector.singularize("equipment").should eq "equipment" }
    it("sheep → sheep") { Ruby2CR::Inflector.singularize("sheep").should eq "sheep" }

    # Capitalization preservation
    it("People → Person") { Ruby2CR::Inflector.singularize("People").should eq "Person" }
  end

  describe ".classify" do
    it("articles → Article") { Ruby2CR::Inflector.classify("articles").should eq "Article" }
    it("comments → Comment") { Ruby2CR::Inflector.classify("comments").should eq "Comment" }
    it("access_tokens → AccessToken") { Ruby2CR::Inflector.classify("access_tokens").should eq "AccessToken" }
    it("article → Article") { Ruby2CR::Inflector.classify("article").should eq "Article" }
  end

  describe ".underscore" do
    it("Article → article") { Ruby2CR::Inflector.underscore("Article").should eq "article" }
    it("AccessToken → access_token") { Ruby2CR::Inflector.underscore("AccessToken").should eq "access_token" }
    it("HTMLParser → html_parser") { Ruby2CR::Inflector.underscore("HTMLParser").should eq "html_parser" }
  end
end
