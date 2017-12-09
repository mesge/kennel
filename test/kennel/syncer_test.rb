# frozen_string_literal: true
require_relative "../test_helper"
require "stringio"

SingleCov.covered!

describe Kennel::Syncer do
  def component(pid, cid, extra = {})
    {
      tags: extra.delete(:tags) || ["service:a"],
      message: "@slack-foo\n-- Managed by kennel #{pid}:#{cid} in test/test_helper.rb, do not modify manually",
      options: {}
    }.merge(extra)
  end

  def monitor(pid, cid, extra = {})
    project = TestProject.new
    project.define_singleton_method(:kennel_id) { pid }
    monitor = Kennel::Models::Monitor.new(
      project,
      query: -> { "avg(last_5m) > #{critical}" },
      kennel_id: -> { cid },
      critical: -> { 1.0 },
      id: -> { extra[:id] }
    )

    # make the diff simple
    monitor.as_json[:options] = {
      escalation_message: nil,
      evaluation_delay: nil
    }
    monitor.as_json.delete_if { |k, _| ![:tags, :message, :options].include?(k) }
    monitor.as_json.merge!(extra)

    monitor
  end

  def dash(pid, cid, extra)
    project = TestProject.new
    project.define_singleton_method(:kennel_id) { pid }
    dash = Kennel::Models::Dash.new(
      TestProject.new({}),
      title: -> { "x" },
      description: -> { "x" },
      kennel_id: -> { cid },
      id: -> { extra[:id].to_s }
    )
    dash.as_json.delete_if { |k, _| ![:description, :options, :graphs, :template_variables].include?(k) }
    dash.as_json.merge!(extra)
    dash
  end

  let(:api) { stub("Api") }
  let(:monitors) { [] }
  let(:dashes) { [] }
  let(:expected) { [] }
  let(:syncer) { Kennel::Syncer.new(api, expected) }

  before do
    Kennel::Progress.stubs(:print).yields
    api.stubs(:list).with("monitor", anything).returns(monitors)
    api.stubs(:list).with("dash", anything).returns(dashes: dashes)
  end

  capture_stdout

  describe "#plan" do
    let(:output) do
      (monitors + dashes).each { |m| m[:id] ||= 123 } # existing components always have an id
      syncer.plan
      stdout.string.gsub(/\e\[\d+m(.*)\e\[0m/, "\\1") # remove colors
    end

    it "does nothing when everything is empty" do
      output.must_equal "Plan:\nNothing to do.\n"
    end

    it "creates missing" do
      expected << monitor("a", "b")
      output.must_equal "Plan:\nCreate a:b\n"
    end

    it "ignores identical" do
      expected << monitor("a", "b")
      monitors << component("a", "b")
      output.must_equal "Plan:\nNothing to do.\n"
    end

    it "ignores readonly attributes since we do not generate them" do
      expected << monitor("a", "b")
      monitors << component("a", "b", created: true)
      output.must_equal "Plan:\nNothing to do.\n"
    end

    it "ignores silencing since that is managed via the UI" do
      expected << monitor("a", "b")
      monitors << component("a", "b", options: { silenced: { "*" => 1 } })
      output.must_equal "Plan:\nNothing to do.\n"
    end

    it "updates when changed" do
      expected << monitor("a", "b", foo: "bar", bar: "foo", nested: { foo: "bar" })
      monitors << component("a", "b", foo: "baz", baz: "foo", nested: { foo: "baz" })
      output.must_equal <<~TEXT
        Plan:
        Update a:b
          -baz \"foo\" -> nil
          ~foo \"baz\" -> \"bar\"
          ~nested.foo \"baz\" -> \"bar\"
          +bar nil -> \"foo\"
      TEXT
    end

    it "shows long updates nicely" do
      expected << monitor("a", "b", foo: "something very long but not too long I do not know")
      monitors << component("a", "b", foo: "something shorter but still very long but also different")
      output.must_equal <<~TEXT
        Plan:
        Update a:b
          ~foo
            \"something shorter but still very long but also different\" ->
            \"something very long but not too long I do not know\"
      TEXT
    end

    it "shows added tags nicely" do
      expected << monitor("a", "b", tags: ["foo", "bar"])
      monitors << component("a", "b", tags: ["foo", "baz"])
      output.must_equal <<~TEXT
        Plan:
        Update a:b
          ~tags[1] \"baz\" -> \"bar\"
      TEXT
    end

    it "deletes deleted" do
      monitors << component("a", "b")
      output.must_equal "Plan:\nDelete a:b\n"
    end

    it "leaves unmanaged alone" do
      monitors << { id: 123, message: "foo", tags: [] }
      output.must_equal "Plan:\nNothing to do.\n"
    end

    it "notifies about duplicate components since they would be ignored otherwise" do
      expected << monitor("a", "b") << monitor("a", "b")
      monitors << component("a", "c") # need something to trigger lookup_map to initialize
      e = assert_raises(RuntimeError) { output }
      e.message.must_equal "Lookup a:b is duplicated"
    end

    it "shows progress" do
      Kennel::Progress.unstub(:print)
      output.gsub(/\.\.\. .*?\d\.\d+s/, "... 0.0s").must_equal(
        "Downloading definitions ... 0.0s\nDiffing ... 0.0s\nPlan:\nNothing to do.\n"
      )
    end

    describe "dashes" do
      in_temp_dir # uses file-cache

      it "can plan for dashes" do
        expected << dash("a", "b", id: 123)
        dashes << {
          id: 123,
          description: "x\n-- Managed by kennel test_project:b in test/test_helper.rb, do not modify manually",
          modified: "2015-12-17T23:12:26.726234+00:00",
          graphs: []
        }
        api.expects(:show).with("dash", 123).returns(dash: {})
        output.must_equal "Plan:\nNothing to do.\n"
      end
    end

    describe "replacement" do
      before do
        expected << monitor("a", "b", id: 234, foo: "bar")
        monitors << component("a", "b", id: 234)
      end

      it "updates via replace" do
        monitors.last[:message] = "nope" # actual is not marked yet
        output.must_equal <<~TEXT
          Plan:
          Update a:b
            ~message \"nope\" -> \"@slack-foo\\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually\"
            +foo nil -> \"bar\"
        TEXT
      end

      it "can update renamed components" do
        expected.last.as_json[:message] = "-- Managed by kennel foo:bar in foo.rb"
        output.must_equal <<~TEXT
          Plan:
          Update foo:bar
            ~message
              \"@slack-foo\\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually\" ->
              \"-- Managed by kennel foo:bar in foo.rb\\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually\"
            +foo nil -> \"bar\"
        TEXT
      end

      it "can update renamed components without other diff" do
        expected.last.as_json.delete(:foo)
        expected.last.as_json[:message] = "-- Managed by kennel foo:bar in foo.rb"
        output.must_equal <<~TEXT
          Plan:
          Update foo:bar
            ~message
              \"@slack-foo\\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually\" ->
              \"-- Managed by kennel foo:bar in foo.rb\\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually\"
        TEXT
      end

      it "complains when id was not found" do
        monitors.pop
        e = assert_raises(RuntimeError) { syncer.plan }
        e.message.must_equal "Unable to find existing monitor with id 234"
      end
    end
  end

  describe "#confirm" do
    before do
      expected << monitor("a", "b")
      STDIN.stubs(:tty?).returns(true)
    end

    it "confirms on y" do
      STDIN.expects(:gets).returns("y\n")
      assert syncer.confirm
      stdout.string.must_equal "\e[31mExecute Plan ? -  press 'y' to continue: \e[0m"
    end

    it "confirms when automated" do
      STDIN.stubs(:tty?).returns(false)
      assert syncer.confirm
    end

    it "denies on n" do
      STDIN.expects(:gets).returns("n\n")
      refute syncer.confirm
    end

    it "denies when nothing changed" do
      expected.clear
      refute syncer.confirm
      stdout.string.must_equal ""
    end
  end

  describe "#update" do
    let(:output) do
      syncer.update
      stdout.string
    end

    it "does nothing when nothing is to do" do
      output.must_equal ""
    end

    it "creates" do
      expected << monitor("a", "b")
      api.expects(:create).with("monitor", expected.first.as_json).returns(expected.first.as_json.merge(id: 123))
      output.must_equal "Created monitor a:b /monitors#123/edit\n"
    end

    it "sets values we do not compare on" do
      expected << monitor("a", "b", type: "event alert", options: { thresholds: { critical: 2 } })
      sent = Marshal.load(Marshal.dump(expected.first.as_json))
      sent[:message] += "\n-- Managed by kennel a:b in test/test_helper.rb, do not modify manually"
      api.expects(:create).with("monitor", sent).returns(sent.merge(id: 123))
      output.must_equal "Created monitor a:b /monitors#123/edit\n"
    end

    it "updates" do
      expected << monitor("a", "b", foo: "bar")
      monitors << component("a", "b", id: 123)
      api.expects(:update).with("monitor", 123, expected.first.as_json).returns(expected.first.as_json.merge(id: 123))
      output.must_equal "Updated monitor a:b /monitors#123/edit\n"
    end

    it "deletes" do
      monitors << component("a", "b", id: 123)
      api.expects(:delete).with("monitor", 123).returns({})
      output.must_equal "Deleted monitor a:b 123\n"
    end

    describe "dashes" do
      in_temp_dir # uses file-cache

      it "can update dashes" do
        expected << dash("a", "b", id: 123)
        dashes << {
          id: 123,
          description: "y\n-- Managed by kennel test_project:b in test/test_helper.rb, do not modify manually",
          modified: "2015-12-17T23:12:26.726234+00:00",
          graphs: []
        }
        api.expects(:show).with("dash", 123).returns(dash: {})
        api.expects(:update).with("dash", 123, expected.first.as_json).returns(expected.first.as_json.merge(id: 123))
        output.must_equal "Updated dash test_project:b /dash/123\n"
      end
    end
  end
end